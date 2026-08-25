import AppKit
import ApplicationServices
import CoreGraphics
import Darwin
import Foundation
import MacBridgeCore

final class SocketClient {
    private var fd: Int32 = -1
    private let writerQueue = DispatchQueue(label: "com.macbridge.socket-writer", qos: .userInteractive)
    private let stateLock = NSCondition()
    private var activeIO = 0
    private var receiveBuffer = [UInt8](repeating: 0, count: 8_192)
    private var receiveOffset = 0
    private var receiveCount = 0
    private var pointerWrites = PointerWriteState()
    private var stopped = false
    var onMessage: ((WireMessage) -> Void)?
    var onDisconnect: ((String) -> Void)?

    func connect(host: String, port: Int, token: String) throws {
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = SOCK_STREAM
        hints.ai_protocol = IPPROTO_TCP
        var addresses: UnsafeMutablePointer<addrinfo>?
        let status = getaddrinfo(host, String(port), &hints, &addresses)
        guard status == 0, let first = addresses else {
            throw NSError(domain: "MacBridge", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "无法解析主机 \(host)：\(String(cString: gai_strerror(status)))"])
        }
        defer { freeaddrinfo(addresses) }

        var current: UnsafeMutablePointer<addrinfo>? = first
        while let address = current {
            let candidate = socket(address.pointee.ai_family, address.pointee.ai_socktype, address.pointee.ai_protocol)
            if candidate >= 0 {
                var one: Int32 = 1
                var timeout = timeval(tv_sec: 1, tv_usec: 0)
                setsockopt(candidate, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout.size(ofValue: one)))
                setsockopt(candidate, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout.size(ofValue: timeout)))
                setsockopt(candidate, SOL_SOCKET, SO_KEEPALIVE, &one, socklen_t(MemoryLayout.size(ofValue: one)))
                var keepalive: Int32 = 3
                setsockopt(candidate, IPPROTO_TCP, TCP_KEEPALIVE, &keepalive,
                           socklen_t(MemoryLayout.size(ofValue: keepalive)))
                setsockopt(candidate, IPPROTO_TCP, TCP_NODELAY, &one, socklen_t(MemoryLayout.size(ofValue: one)))
                if connectWithTimeout(candidate, address: address.pointee.ai_addr,
                                      length: address.pointee.ai_addrlen) {
                    stateLock.lock()
                    fd = candidate
                    stateLock.unlock()
                    break
                }
                Darwin.close(candidate)
            }
            current = address.pointee.ai_next
        }
        guard fd >= 0 else {
            throw NSError(domain: "MacBridge", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "无法连接到 \(host):\(port)"])
        }

        stateLock.lock()
        stopped = false
        stateLock.unlock()
        guard sendBlocking(WireMessage(type: "auth", token: token)),
              let line = readLine(maxBytes: 65_536, timeoutMilliseconds: 5_000),
              let reply = try? JSONDecoder().decode(WireMessage.self, from: line),
              reply.type == "auth_ok" else {
            close()
            throw NSError(domain: "MacBridge", code: 3,
                          userInfo: [NSLocalizedDescriptionKey: "认证失败，请检查两端 token"])
        }
    }

    private func connectWithTimeout(_ socket: Int32, address: UnsafePointer<sockaddr>?,
                                    length: socklen_t) -> Bool {
        let flags = fcntl(socket, F_GETFL, 0)
        guard flags >= 0, fcntl(socket, F_SETFL, flags | O_NONBLOCK) == 0 else { return false }
        defer { _ = fcntl(socket, F_SETFL, flags) }
        if Darwin.connect(socket, address, length) == 0 { return true }
        guard errno == EINPROGRESS else { return false }
        var descriptor = pollfd(fd: socket, events: Int16(POLLOUT), revents: 0)
        guard poll(&descriptor, 1, 3_000) > 0 else { return false }
        var error: Int32 = 0
        var errorLength = socklen_t(MemoryLayout.size(ofValue: error))
        guard getsockopt(socket, SOL_SOCKET, SO_ERROR, &error, &errorLength) == 0 else { return false }
        return error == 0
    }

    func startReading() {
        Thread.detachNewThread { [weak self] in
            guard let self else { return }
            while let data = self.readLine(maxBytes: 65_536) {
                guard let message = try? JSONDecoder().decode(WireMessage.self, from: data) else { continue }
                self.onMessage?(message)
            }
            self.finish(reason: "Windows 连接已关闭")
        }
    }

    @discardableResult func send(_ message: WireMessage) -> Bool {
        stateLock.lock()
        let connected = !stopped && fd >= 0
        let isPointer = message.type == "move" || message.type == "scroll"
        var generation: Int?
        if connected, message.type == "move", let dx = message.dx, let dy = message.dy {
            generation = pointerWrites.addMovement(dx: dx, dy: dy)
        } else if connected, message.type == "scroll", let dx = message.dx, let dy = message.dy {
            generation = pointerWrites.addScrolling(dx: dx, dy: dy)
        }
        let boundary = connected && !isPointer ? pointerWrites.boundary() : nil
        stateLock.unlock()
        guard connected else { return false }
        if let generation {
            writerQueue.async { [weak self] in self?.sendPendingPointer(generation: generation) }
        } else if !isPointer {
            writerQueue.async { [weak self] in
                guard let self else { return }
                guard self.writePointer(movement: boundary?.movement, scrolling: boundary?.scrolling),
                      self.sendBlocking(message) else {
                    self.finish(reason: "向 Windows 发送数据失败")
                    return
                }
            }
        }
        return true
    }

    private func sendPendingPointer(generation: Int) {
        stateLock.lock()
        let batch = pointerWrites.drain(generation: generation)
        stateLock.unlock()
        guard let batch else { return }
        if !writePointer(movement: batch.movement, scrolling: batch.scrolling) {
            finish(reason: "向 Windows 发送数据失败")
        }
    }

    private func writePointer(movement: (dx: Double, dy: Double)?,
                              scrolling: (dx: Double, dy: Double)?) -> Bool {
        if let movement,
           !sendBlocking(WireMessage(type: "move", dx: movement.dx, dy: movement.dy)) { return false }
        if let scrolling,
           !sendBlocking(WireMessage(type: "scroll", dx: scrolling.dx, dy: scrolling.dy)) { return false }
        return true
    }

    private func sendBlocking(_ message: WireMessage) -> Bool {
        guard let encoded = try? JSONEncoder().encode(message) else { return false }
        var data = encoded
        data.append(0x0A)
        guard let socket = beginIO() else { return false }
        defer { endIO() }
        var sent = 0
        return data.withUnsafeBytes { bytes -> Bool in
            guard let base = bytes.baseAddress else { return false }
            while sent < bytes.count {
                let count = Darwin.send(socket, base.advanced(by: sent), bytes.count - sent, 0)
                if count <= 0 { return false }
                sent += count
            }
            return true
        }
    }

    private func readLine(maxBytes: Int, timeoutMilliseconds: Int32? = nil) -> Data? {
        var line = Data()
        while true {
            if receiveOffset < receiveCount {
                let newline = receiveBuffer[receiveOffset..<receiveCount].firstIndex(of: 0x0A)
                let end = newline ?? receiveCount
                guard line.count + end - receiveOffset <= maxBytes else { return nil }
                line.append(contentsOf: receiveBuffer[receiveOffset..<end])
                receiveOffset = newline.map { $0 + 1 } ?? receiveCount
                if newline != nil {
                    if line.last == 0x0D { line.removeLast() }
                    return line
                }
            }

            guard let socket = beginIO() else { return nil }
            if let timeoutMilliseconds {
                var descriptor = pollfd(fd: socket, events: Int16(POLLIN), revents: 0)
                if poll(&descriptor, 1, timeoutMilliseconds) <= 0 {
                    endIO()
                    return nil
                }
            }
            let received = receiveBuffer.withUnsafeMutableBytes { bytes in
                Darwin.recv(socket, bytes.baseAddress, bytes.count, 0)
            }
            endIO()
            guard received > 0 else { return nil }
            receiveOffset = 0
            receiveCount = received
        }
    }

    private func beginIO() -> Int32? {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard !stopped, fd >= 0 else { return nil }
        activeIO += 1
        return fd
    }

    private func endIO() {
        stateLock.lock()
        activeIO -= 1
        stateLock.broadcast()
        stateLock.unlock()
    }

    func close() { _ = closeSocket() }

    private func closeSocket() -> Bool {
        stateLock.lock()
        let shouldNotify = !stopped
        stopped = true
        pointerWrites.reset()
        let socket = fd
        fd = -1
        if socket >= 0 { Darwin.shutdown(socket, SHUT_RDWR) }
        while activeIO > 0 { stateLock.wait() }
        stateLock.unlock()
        if socket >= 0 { Darwin.close(socket) }
        return shouldNotify
    }

    private func finish(reason: String) {
        if closeSocket() { onDisconnect?(reason) }
    }
}

final class BridgeController {
    private let config: MacConfig
    private let client: SocketClient
    private var state = BridgeState()
    private var crossing: CrossingAccumulator
    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var flushTimer: DispatchSourceTimer?
    private var watchdogTimer: DispatchSourceTimer?
    private var movement = DeltaAccumulator()
    private var scrolling = DeltaAccumulator()
    private var localModifierCodes = Set<Int64>()
    private var forwardedModifierCodes = Set<Int64>()
    private var tapRecoveryFailures = 0
    private var savedScreen = CGRect.zero
    private var savedDisplay = CGMainDisplayID()
    private var cursorHideDepth = 0
    private var lastHeartbeat: TimeInterval = 0
    private var shuttingDown = false
    var onConnectionLost: ((String) -> Void)?

    init(config: MacConfig, client: SocketClient) {
        self.config = config
        self.client = client
        self.crossing = CrossingAccumulator(threshold: config.crossingThreshold)
    }

    func start() throws {
        let types: [CGEventType] = [
            .mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged,
            .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp,
            .otherMouseDown, .otherMouseUp, .scrollWheel, .keyDown, .keyUp, .flagsChanged
        ]
        let mask = types.reduce(CGEventMask(0)) { $0 | (CGEventMask(1) << $1.rawValue) }
        guard let created = CGEvent.tapCreate(tap: .cgSessionEventTap,
                                               place: .headInsertEventTap,
                                               options: .defaultTap,
                                               eventsOfInterest: mask,
                                               callback: eventTapCallback,
                                               userInfo: Unmanaged.passUnretained(self).toOpaque()) else {
            throw NSError(domain: "MacBridge", code: 4,
                          userInfo: [NSLocalizedDescriptionKey: "无法捕获输入，请授予辅助功能权限"])
        }
        tap = created
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, created, 0)
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: created, enable: true)
        startTimers()
    }

    func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            if state.mode == .pcActive {
                resynchronizeModifiers(forward: true)
                hideMacCursor()
            }
            return nil
        }

        if state.mode == .macActive {
            if type == .flagsChanged { updateModifierState(event, forward: false) }
            guard isMovement(type) else { return Unmanaged.passUnretained(event) }
            let point = event.location
            let screen = display(at: point)
            let dy = sanitizedDelta(event.getDoubleValueField(.mouseEventDeltaY), scale: 1, limit: 200)
            let atTop = point.x.isFinite && point.y.isFinite && screen.bounds.width > 0 &&
                point.y <= screen.bounds.minY + config.edgeThreshold
            if crossing.update(atEdge: atTop, outwardDelta: -dy,
                               now: ProcessInfo.processInfo.systemUptime) {
                enterPC(at: point, screen: screen)
                return nil
            }
            return Unmanaged.passUnretained(event)
        }

        switch type {
        case .mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged:
            movement.add(
                dx: sanitizedDelta(event.getDoubleValueField(.mouseEventDeltaX), scale: config.sensitivity),
                dy: sanitizedDelta(event.getDoubleValueField(.mouseEventDeltaY), scale: config.sensitivity)
            )
        case .leftMouseDown, .rightMouseDown, .otherMouseDown:
            flushPointerInput()
            send(WireMessage(type: "mouse_down", button: mouseButton(type: type)))
        case .leftMouseUp, .rightMouseUp, .otherMouseUp:
            flushPointerInput()
            send(WireMessage(type: "mouse_up", button: mouseButton(type: type)))
        case .scrollWheel:
            scrolling.add(
                dx: sanitizedDelta(event.getDoubleValueField(.scrollWheelEventPointDeltaAxis2), scale: config.scrollScale),
                dy: sanitizedDelta(event.getDoubleValueField(.scrollWheelEventPointDeltaAxis1), scale: config.scrollScale)
            )
        case .keyDown, .keyUp:
            flushPointerInput()
            guard let key = keyName(code: event.getIntegerValueField(.keyboardEventKeycode)) else { break }
            send(WireMessage(type: type == .keyDown ? "key_down" : "key_up",
                             key: key, meta: modifierNames(event.flags)))
        case .flagsChanged:
            flushPointerInput()
            updateModifierState(event, forward: true)
        default:
            break
        }
        return nil
    }

    func receive(_ message: WireMessage) {
        guard message.type == "return_mac", state.mode == .pcActive,
              let ratio = message.xRatio, ratio.isFinite else { return }
        restoreMac(ratio: ratio)
    }

    func connectionLost(_ reason: String) {
        guard !shuttingDown else { return }
        stop()
        onConnectionLost?(reason)
    }

    func stop() {
        guard !shuttingDown else { return }
        shuttingDown = true
        safetyRestore()
        flushTimer?.cancel()
        watchdogTimer?.cancel()
        flushTimer = nil
        watchdogTimer = nil
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let source = runLoopSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        client.close()
    }

    private func enterPC(at point: CGPoint, screen: (id: CGDirectDisplayID, bounds: CGRect)) {
        guard state.mode == .macActive else { return }
        savedDisplay = screen.id
        savedScreen = screen.bounds
        guard setCursorAssociation(associated: false) else {
            crossing.reset()
            return
        }
        guard hideMacCursor(), state.enterPC() else {
            _ = setCursorAssociation(associated: true)
            _ = restoreMacCursorVisibility()
            return
        }
        let ratio = clampedRatio(position: point.x, origin: screen.bounds.minX, length: screen.bounds.width)
        movement.reset()
        scrolling.reset()
        resynchronizeModifiers(forward: false)
        forwardedModifierCodes.removeAll()
        if client.send(WireMessage(type: "enter_pc", xRatio: ratio)) {
            forwardCurrentModifiers()
        } else {
            connectionLost("发送失败")
        }
    }

    private func restoreMac(ratio: Double) {
        guard state.mode == .pcActive else { return }
        guard setCursorAssociation(associated: true), restoreMacCursorVisibility() else {
            connectionLost("无法恢复 Mac 鼠标")
            return
        }
        _ = state.returnToMac()
        crossing.reset()
        movement.reset()
        scrolling.reset()
        forwardedModifierCodes.removeAll()
        let x = clampedPosition(ratio: ratio, origin: savedScreen.minX, length: savedScreen.width)
        CGWarpMouseCursorPosition(CGPoint(x: x, y: savedScreen.minY + 2))
    }

    private func safetyRestore() {
        if state.mode == .pcActive { _ = state.returnToMac() }
        crossing.reset()
        movement.reset()
        scrolling.reset()
        forwardedModifierCodes.removeAll()
        _ = setCursorAssociation(associated: true)
        _ = restoreMacCursorVisibility()
    }

    private func startTimers() {
        let flush = DispatchSource.makeTimerSource(queue: .main)
        flush.schedule(deadline: .now() + .milliseconds(8), repeating: .milliseconds(8), leeway: .milliseconds(2))
        flush.setEventHandler { [weak self] in self?.flushPointerInput() }
        flush.resume()
        flushTimer = flush

        let watchdog = DispatchSource.makeTimerSource(queue: .main)
        watchdog.schedule(deadline: .now() + .milliseconds(250), repeating: .milliseconds(250),
                          leeway: .milliseconds(50))
        watchdog.setEventHandler { [weak self] in self?.monitorCapture() }
        watchdog.resume()
        watchdogTimer = watchdog
    }

    private func flushPointerInput() {
        guard state.mode == .pcActive else {
            movement.reset()
            scrolling.reset()
            return
        }
        if let delta = movement.drain() {
            send(WireMessage(type: "move", dx: delta.dx, dy: delta.dy))
        }
        if let delta = scrolling.drain() {
            send(WireMessage(type: "scroll", dx: delta.dx, dy: delta.dy))
        }
    }

    private func monitorCapture() {
        guard !shuttingDown, let tap else { return }
        let now = ProcessInfo.processInfo.systemUptime
        if now < lastHeartbeat || now - lastHeartbeat >= 2 {
            lastHeartbeat = now
            send(WireMessage(type: "ping"))
        }
        if !CGEvent.tapIsEnabled(tap: tap) {
            CGEvent.tapEnable(tap: tap, enable: true)
            if !CGEvent.tapIsEnabled(tap: tap) {
                tapRecoveryFailures += 1
                if tapRecoveryFailures >= 3 { connectionLost("系统已禁用输入捕获") }
                return
            }
            if state.mode == .pcActive {
                resynchronizeModifiers(forward: true)
                if !hideMacCursor() {
                    tapRecoveryFailures += 1
                    if tapRecoveryFailures >= 3 { connectionLost("无法隐藏 Mac 鼠标") }
                    return
                }
            }
        }
        if state.mode == .pcActive, cursorHideDepth == 0, !hideMacCursor() {
            tapRecoveryFailures += 1
            if tapRecoveryFailures >= 3 { connectionLost("无法隐藏 Mac 鼠标") }
            return
        }
        if state.mode == .pcActive, !setCursorAssociation(associated: false) {
            tapRecoveryFailures += 1
            if tapRecoveryFailures >= 3 { connectionLost("无法锁定 Mac 鼠标") }
            return
        }
        tapRecoveryFailures = 0
    }

    func reassertCapture() {
        guard state.mode == .pcActive else { return }
        if let tap, !CGEvent.tapIsEnabled(tap: tap) {
            CGEvent.tapEnable(tap: tap, enable: true)
            guard CGEvent.tapIsEnabled(tap: tap) else { return }
        }
        resynchronizeModifiers(forward: true)
        guard setCursorAssociation(associated: false), hideMacCursor() else { return }
    }

    private func setCursorAssociation(associated: Bool) -> Bool {
        for _ in 0..<3 where CGAssociateMouseAndMouseCursorPosition(boolean_t(associated ? 1 : 0)) == .success {
            return true
        }
        return false
    }

    @discardableResult private func hideMacCursor() -> Bool {
        guard CGDisplayHideCursor(savedDisplay) == .success else { return false }
        cursorHideDepth += 1
        return true
    }

    @discardableResult private func restoreMacCursorVisibility() -> Bool {
        while cursorHideDepth > 0 {
            var result = CGDisplayShowCursor(savedDisplay)
            if result != .success { result = CGDisplayShowCursor(CGMainDisplayID()) }
            guard result == .success else { return false }
            cursorHideDepth -= 1
        }
        return true
    }

    private func send(_ message: WireMessage) {
        if !client.send(message) { connectionLost("发送失败") }
    }

    private func display(at point: CGPoint) -> (id: CGDirectDisplayID, bounds: CGRect) {
        var id = CGMainDisplayID()
        var count: UInt32 = 0
        CGGetDisplaysWithPoint(point, 1, &id, &count)
        if count == 0 { id = CGMainDisplayID() }
        return (id, CGDisplayBounds(id))
    }

    private func isMovement(_ type: CGEventType) -> Bool {
        [.mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged].contains(type)
    }

    private func mouseButton(type: CGEventType) -> String {
        if type == .leftMouseDown || type == .leftMouseUp { return "left" }
        if type == .rightMouseDown || type == .rightMouseUp { return "right" }
        return "middle"
    }

    private func updateModifierState(_ event: CGEvent, forward: Bool) {
        let code = event.getIntegerValueField(.keyboardEventKeycode)
        guard let key = keyName(code: code) else { return }
        if code == 57 {
            if forward {
                send(WireMessage(type: "key_down", key: key, meta: modifierNames(event.flags)))
                send(WireMessage(type: "key_up", key: key, meta: modifierNames(event.flags)))
            }
            return
        }
        guard [54, 55, 56, 58, 59, 60, 61, 62].contains(code) else { return }
        let isDown = CGEventSource.keyState(.combinedSessionState, key: CGKeyCode(code))
        if isDown { localModifierCodes.insert(code) } else { localModifierCodes.remove(code) }
        guard forward else { return }
        if isDown {
            if forwardedModifierCodes.insert(code).inserted {
                send(WireMessage(type: "key_down", key: key, meta: modifierNames(event.flags)))
            }
        } else if forwardedModifierCodes.remove(code) != nil {
            send(WireMessage(type: "key_up", key: key, meta: modifierNames(event.flags)))
        }
    }

    private func resynchronizeModifiers(forward: Bool) {
        let codes: [Int64] = [54, 55, 56, 58, 59, 60, 61, 62]
        let actual = Set(codes.filter {
            CGEventSource.keyState(.combinedSessionState, key: CGKeyCode($0))
        })
        localModifierCodes = actual
        guard forward else { return }
        for code in forwardedModifierCodes.subtracting(actual).sorted() {
            if let key = keyName(code: code) { send(WireMessage(type: "key_up", key: key)) }
            forwardedModifierCodes.remove(code)
        }
        forwardCurrentModifiers()
    }

    private func forwardCurrentModifiers() {
        for code in localModifierCodes.sorted() where !forwardedModifierCodes.contains(code) {
            if let key = keyName(code: code) {
                forwardedModifierCodes.insert(code)
                send(WireMessage(type: "key_down", key: key))
            }
        }
    }

}

private func eventTapCallback(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent,
                              userInfo: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    guard let userInfo else { return Unmanaged.passUnretained(event) }
    return Unmanaged<BridgeController>.fromOpaque(userInfo).takeUnretainedValue().handle(type: type, event: event)
}

private func modifierNames(_ flags: CGEventFlags) -> [String] {
    var names: [String] = []
    if flags.contains(.maskShift) { names.append("shift") }
    if flags.contains(.maskControl) { names.append("control") }
    if flags.contains(.maskAlternate) { names.append("option") }
    if flags.contains(.maskCommand) { names.append("command") }
    return names
}

private func keyName(code: Int64) -> String? {
    if let modifier = windowsModifierKey(macKeyCode: code) { return modifier }
    let keys: [Int64: String] = [
        0:"A", 1:"S", 2:"D", 3:"F", 4:"H", 5:"G", 6:"Z", 7:"X", 8:"C", 9:"V",
        11:"B", 12:"Q", 13:"W", 14:"E", 15:"R", 16:"Y", 17:"T", 18:"1", 19:"2",
        20:"3", 21:"4", 22:"6", 23:"5", 24:"=", 25:"9", 26:"7", 27:"-", 28:"8",
        29:"0", 30:"]", 31:"O", 32:"U", 33:"[", 34:"I", 35:"P", 36:"ENTER",
        37:"L", 38:"J", 39:"'", 40:"K", 41:";", 42:"\\", 43:",", 44:"/", 45:"N",
        46:"M", 47:".", 48:"TAB", 49:"SPACE", 50:"`", 51:"BACKSPACE", 53:"ESCAPE",
        57:"CAPSLOCK", 64:"F17", 65:"DECIMAL", 67:"MULTIPLY",
        69:"ADD", 71:"NUMLOCK", 75:"DIVIDE", 76:"NUMENTER", 78:"SUBTRACT", 79:"F18",
        80:"F19", 81:"NUM=", 82:"NUM0", 83:"NUM1", 84:"NUM2", 85:"NUM3", 86:"NUM4",
        87:"NUM5", 88:"NUM6", 89:"NUM7", 91:"NUM8", 92:"NUM9", 96:"F5", 97:"F6",
        98:"F7", 99:"F3", 100:"F8", 101:"F9", 103:"F11", 105:"F13", 106:"F16",
        107:"F14", 109:"F10", 111:"F12", 113:"F15", 114:"INSERT", 115:"HOME",
        116:"PAGEUP", 117:"DELETE", 118:"F4", 119:"END", 120:"F2", 121:"PAGEDOWN",
        122:"F1", 123:"LEFT", 124:"RIGHT", 125:"DOWN", 126:"UP"
    ]
    return keys[code]
}

private func loadConfig(path: String) throws -> MacConfig {
    let data = try Data(contentsOf: URL(fileURLWithPath: path))
    let config = try JSONDecoder().decode(MacConfig.self, from: data)
    try config.validate()
    return config
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let statusLine = NSMenuItem(title: "正在启动…", action: nil, keyEquivalent: "")
    private var controller: BridgeController?
    private var connectAttempt = UUID()
    private var retryTimer: Timer?
    private var sessionActive = true

    private var configURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MacBridge/macbridge.json")
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        statusItem.button?.image = NSImage(systemSymbolName: "keyboard", accessibilityDescription: "MacBridge")
        statusItem.button?.toolTip = "MacBridge"

        let menu = NSMenu()
        statusLine.isEnabled = false
        menu.addItem(statusLine)
        menu.addItem(.separator())
        menu.addItem(item("重新连接", #selector(reconnect), "r"))
        menu.addItem(item("编辑配置…", #selector(openConfig), ","))
        menu.addItem(item("打开使用说明…", #selector(openHelp), ""))
        menu.addItem(.separator())
        menu.addItem(item("退出 MacBridge", #selector(quit), "q"))
        statusItem.menu = menu
        let workspace = NSWorkspace.shared.notificationCenter
        workspace.addObserver(self, selector: #selector(workspaceFocusChanged),
                              name: NSWorkspace.didActivateApplicationNotification, object: nil)
        workspace.addObserver(self, selector: #selector(sessionResigned),
                              name: NSWorkspace.sessionDidResignActiveNotification, object: nil)
        workspace.addObserver(self, selector: #selector(sessionBecameActive),
                              name: NSWorkspace.sessionDidBecomeActiveNotification, object: nil)
        workspace.addObserver(self, selector: #selector(systemWillSleep),
                              name: NSWorkspace.willSleepNotification, object: nil)
        workspace.addObserver(self, selector: #selector(systemWillSleep),
                              name: NSWorkspace.screensDidSleepNotification, object: nil)
        workspace.addObserver(self, selector: #selector(systemDidWake),
                              name: NSWorkspace.didWakeNotification, object: nil)
        workspace.addObserver(self, selector: #selector(systemDidWake),
                              name: NSWorkspace.screensDidWakeNotification, object: nil)

        do {
            if try ensureConfig() { showWelcome() }
        } catch {
            setStatus("配置创建失败：\(error.localizedDescription)")
        }
        reconnect()
    }

    func applicationWillTerminate(_ notification: Notification) {
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        retryTimer?.invalidate()
        connectAttempt = UUID()
        controller?.stop()
    }

    @objc private func workspaceFocusChanged(_ notification: Notification) { controller?.reassertCapture() }

    @objc private func sessionResigned(_ notification: Notification) {
        sessionActive = false
        disconnectForPause("会话已锁定")
    }

    @objc private func sessionBecameActive(_ notification: Notification) {
        sessionActive = true
        reconnect()
    }

    @objc private func systemWillSleep(_ notification: Notification) { disconnectForPause("系统正在睡眠") }

    @objc private func systemDidWake(_ notification: Notification) {
        if sessionActive { reconnect() }
    }

    private func disconnectForPause(_ status: String) {
        retryTimer?.invalidate()
        retryTimer = nil
        connectAttempt = UUID()
        controller?.stop()
        controller = nil
        setStatus(status)
    }

    @objc private func reconnect() {
        guard sessionActive else { return }
        retryTimer?.invalidate()
        retryTimer = nil
        connectAttempt = UUID()
        controller?.stop()
        controller = nil
        setStatus("正在连接…")

        let config: MacConfig
        do { config = try loadConfig(path: configURL.path) }
        catch {
            setStatus("需要配置：请点击“编辑配置…”")
            return
        }

        let prompt = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        guard AXIsProcessTrustedWithOptions(prompt) else {
            setStatus("需要开启“辅助功能”权限")
            return
        }
        guard CGPreflightListenEventAccess() || CGRequestListenEventAccess() else {
            setStatus("需要开启“输入监控”权限，授权后请重新连接")
            return
        }

        let attempt = connectAttempt
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let client = SocketClient()
            do {
                try client.connect(host: config.host, port: config.port, token: config.token)
                DispatchQueue.main.async {
                    guard let self, self.connectAttempt == attempt else {
                        client.close()
                        return
                    }
                    self.activate(client: client, config: config)
                }
            } catch {
                DispatchQueue.main.async {
                    guard let self, self.connectAttempt == attempt else { return }
                    self.setStatus("连接失败：\(error.localizedDescription)")
                    self.scheduleReconnect()
                }
            }
        }
    }

    private func scheduleReconnect() {
        guard sessionActive, retryTimer == nil else { return }
        retryTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: false) { [weak self] _ in
            self?.reconnect()
        }
    }

    private func activate(client: SocketClient, config: MacConfig) {
        let controller = BridgeController(config: config, client: client)
        client.onMessage = { [weak controller] message in
            DispatchQueue.main.async { controller?.receive(message) }
        }
        client.onDisconnect = { [weak controller] reason in
            DispatchQueue.main.async { controller?.connectionLost(reason) }
        }
        controller.onConnectionLost = { [weak self, weak controller] reason in
            guard self?.controller === controller else { return }
            self?.controller = nil
            self?.setStatus("已断开：\(reason)，正在重连…")
            self?.scheduleReconnect()
        }
        do {
            try controller.start()
            self.controller = controller
            client.startReading()
            setStatus("已连接 \(config.host):\(config.port)")
        } catch {
            controller.stop()
            setStatus("启动失败：\(error.localizedDescription)")
        }
    }

    @objc private func openConfig() {
        do { _ = try ensureConfig(); openInTextEdit(configURL) }
        catch { setStatus("无法打开配置：\(error.localizedDescription)") }
    }

    @objc private func openHelp() {
        if let bundled = Bundle.main.url(forResource: "README", withExtension: "md") {
            openInTextEdit(bundled)
        } else {
            NSWorkspace.shared.open(URL(string: "https://github.com/lornezhang66/macBridgeWin#readme")!)
        }
    }

    @objc private func quit() { NSApp.terminate(nil) }

    private func ensureConfig() throws -> Bool {
        guard !FileManager.default.fileExists(atPath: configURL.path) else { return false }
        try FileManager.default.createDirectory(at: configURL.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        let token = UUID().uuidString.replacingOccurrences(of: "-", with: "")
        let template = """
        {
          "host": "192.168.1.100",
          "port": 24800,
          "token": "\(token)",
          "pcSide": "top",
          "edgeThreshold": 2,
          "crossingThreshold": 10,
          "returnThreshold": 10,
          "sensitivity": 1.0,
          "scrollScale": 1.0
        }
        """
        try template.write(to: configURL, atomically: true, encoding: .utf8)
        return true
    }

    private func showWelcome() {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "MacBridge 已安装"
        alert.informativeText = "菜单栏中的键盘图标会显示连接状态。请先填写 Windows IP，并把同一个令牌填入 Windows 配置。"
        alert.addButton(withTitle: "编辑配置")
        alert.addButton(withTitle: "稍后")
        if alert.runModal() == .alertFirstButtonReturn { openConfig() }
    }

    private func openInTextEdit(_ url: URL) {
        let configuration = NSWorkspace.OpenConfiguration()
        NSWorkspace.shared.open([url], withApplicationAt: URL(fileURLWithPath: "/System/Applications/TextEdit.app"),
                                configuration: configuration)
    }

    private func setStatus(_ text: String) {
        statusLine.title = text
        statusItem.button?.toolTip = "MacBridge — \(text)"
    }

    private func item(_ title: String, _ action: Selector, _ key: String) -> NSMenuItem {
        let menuItem = NSMenuItem(title: title, action: action, keyEquivalent: key)
        menuItem.target = self
        return menuItem
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
