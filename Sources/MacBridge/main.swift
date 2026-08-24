import ApplicationServices
import CoreGraphics
import Darwin
import Foundation
import MacBridgeCore

final class SocketClient {
    private var fd: Int32 = -1
    private let writeLock = NSLock()
    private let stateLock = NSLock()
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
                          userInfo: [NSLocalizedDescriptionKey: "cannot resolve \(host): \(String(cString: gai_strerror(status)))"])
        }
        defer { freeaddrinfo(addresses) }

        var current: UnsafeMutablePointer<addrinfo>? = first
        while let address = current {
            let candidate = socket(address.pointee.ai_family, address.pointee.ai_socktype, address.pointee.ai_protocol)
            if candidate >= 0 {
                var one: Int32 = 1
                setsockopt(candidate, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout.size(ofValue: one)))
                if Darwin.connect(candidate, address.pointee.ai_addr, address.pointee.ai_addrlen) == 0 {
                    fd = candidate
                    break
                }
                Darwin.close(candidate)
            }
            current = address.pointee.ai_next
        }
        guard fd >= 0 else {
            throw NSError(domain: "MacBridge", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "cannot connect to \(host):\(port)"])
        }

        guard send(WireMessage(type: "auth", token: token)),
              let line = readLine(maxBytes: 65_536),
              let reply = try? JSONDecoder().decode(WireMessage.self, from: line),
              reply.type == "auth_ok" else {
            close()
            throw NSError(domain: "MacBridge", code: 3,
                          userInfo: [NSLocalizedDescriptionKey: "authentication failed"])
        }
    }

    func startReading() {
        Thread.detachNewThread { [weak self] in
            guard let self else { return }
            while let data = self.readLine(maxBytes: 65_536) {
                guard let message = try? JSONDecoder().decode(WireMessage.self, from: data) else { continue }
                self.onMessage?(message)
            }
            self.finish(reason: "Windows connection closed")
        }
    }

    @discardableResult func send(_ message: WireMessage) -> Bool {
        guard let encoded = try? JSONEncoder().encode(message) else { return false }
        var data = encoded
        data.append(0x0A)
        writeLock.lock()
        defer { writeLock.unlock() }
        var sent = 0
        let result = data.withUnsafeBytes { bytes -> Bool in
            guard let base = bytes.baseAddress else { return false }
            while sent < bytes.count {
                let count = Darwin.send(fd, base.advanced(by: sent), bytes.count - sent, 0)
                if count <= 0 { return false }
                sent += count
            }
            return true
        }
        return result
    }

    private func readLine(maxBytes: Int) -> Data? {
        var line = Data()
        var byte: UInt8 = 0
        while line.count < maxBytes {
            let count = Darwin.recv(fd, &byte, 1, 0)
            guard count > 0 else { return nil }
            if byte == 0x0A { return line }
            if byte != 0x0D { line.append(byte) }
        }
        return nil
    }

    func close() {
        stateLock.lock()
        stopped = true
        let socket = fd
        fd = -1
        stateLock.unlock()
        if socket >= 0 {
            Darwin.shutdown(socket, SHUT_RDWR)
            Darwin.close(socket)
        }
    }

    private func finish(reason: String) {
        stateLock.lock()
        let shouldNotify = !stopped
        stopped = true
        let socket = fd
        fd = -1
        stateLock.unlock()
        if socket >= 0 { Darwin.close(socket) }
        if shouldNotify { onDisconnect?(reason) }
    }
}

final class BridgeController {
    private let config: MacConfig
    private let client: SocketClient
    private var state = BridgeState()
    private var crossing: CrossingAccumulator
    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var savedScreen = CGRect.zero
    private var savedDisplay = CGMainDisplayID()
    private var cursorHidden = false
    private var shuttingDown = false

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
                          userInfo: [NSLocalizedDescriptionKey: "cannot create event tap; grant Accessibility permission"])
        }
        tap = created
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, created, 0)
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: created, enable: true)
    }

    func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }

        if state.mode == .macActive {
            guard isMovement(type) else { return Unmanaged.passUnretained(event) }
            let point = event.location
            let screen = display(at: point)
            let dy = event.getDoubleValueField(.mouseEventDeltaY)
            let atTop = point.y <= screen.bounds.minY + config.edgeThreshold
            if crossing.update(atEdge: atTop, outwardDelta: -dy,
                               now: ProcessInfo.processInfo.systemUptime) {
                enterPC(at: point, screen: screen)
                return nil
            }
            return Unmanaged.passUnretained(event)
        }

        switch type {
        case .mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged:
            send(WireMessage(type: "move",
                             dx: event.getDoubleValueField(.mouseEventDeltaX) * config.sensitivity,
                             dy: event.getDoubleValueField(.mouseEventDeltaY) * config.sensitivity))
        case .leftMouseDown, .rightMouseDown, .otherMouseDown:
            send(WireMessage(type: "mouse_down", button: mouseButton(type: type)))
        case .leftMouseUp, .rightMouseUp, .otherMouseUp:
            send(WireMessage(type: "mouse_up", button: mouseButton(type: type)))
        case .scrollWheel:
            let dx = event.getDoubleValueField(.scrollWheelEventPointDeltaAxis2) * config.scrollScale
            let dy = event.getDoubleValueField(.scrollWheelEventPointDeltaAxis1) * config.scrollScale
            send(WireMessage(type: "scroll", dx: dx, dy: dy))
        case .keyDown, .keyUp:
            guard let key = keyName(code: event.getIntegerValueField(.keyboardEventKeycode)) else { break }
            send(WireMessage(type: type == .keyDown ? "key_down" : "key_up",
                             key: key, meta: modifierNames(event.flags)))
        case .flagsChanged:
            forwardModifier(event)
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
        fputs("macbridge: \(reason)\n", stderr)
        safetyRestore()
        CFRunLoopStop(CFRunLoopGetMain())
    }

    func shutdown() {
        guard !shuttingDown else { return }
        shuttingDown = true
        safetyRestore()
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let source = runLoopSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        client.close()
        CFRunLoopStop(CFRunLoopGetMain())
    }

    private func enterPC(at point: CGPoint, screen: (id: CGDirectDisplayID, bounds: CGRect)) {
        guard state.enterPC() else { return }
        savedDisplay = screen.id
        savedScreen = screen.bounds
        let ratio = clampedRatio(position: point.x, origin: screen.bounds.minX, length: screen.bounds.width)
        CGWarpMouseCursorPosition(CGPoint(x: point.x, y: screen.bounds.minY))
        CGAssociateMouseAndMouseCursorPosition(boolean_t(0))
        CGDisplayHideCursor(screen.id)
        cursorHidden = true
        if !client.send(WireMessage(type: "enter_pc", xRatio: ratio)) {
            connectionLost("send failed")
        }
    }

    private func restoreMac(ratio: Double) {
        guard state.returnToMac() else { return }
        crossing.reset()
        CGAssociateMouseAndMouseCursorPosition(boolean_t(1))
        if cursorHidden {
            CGDisplayShowCursor(savedDisplay)
            cursorHidden = false
        }
        let x = clampedPosition(ratio: ratio, origin: savedScreen.minX, length: savedScreen.width)
        CGWarpMouseCursorPosition(CGPoint(x: x, y: savedScreen.minY + 2))
    }

    private func safetyRestore() {
        if state.mode == .pcActive { _ = state.returnToMac() }
        crossing.reset()
        CGAssociateMouseAndMouseCursorPosition(boolean_t(1))
        if cursorHidden {
            CGDisplayShowCursor(savedDisplay)
            cursorHidden = false
        }
    }

    private func send(_ message: WireMessage) {
        if !client.send(message) { connectionLost("send failed") }
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

    private func forwardModifier(_ event: CGEvent) {
        let code = event.getIntegerValueField(.keyboardEventKeycode)
        guard let key = keyName(code: code) else { return }
        let flag: CGEventFlags
        switch code {
        case 56, 60: flag = .maskShift
        case 59, 62: flag = .maskControl
        case 58, 61: flag = .maskAlternate
        case 55, 54: flag = .maskCommand
        case 57:
            send(WireMessage(type: "key_down", key: key, meta: modifierNames(event.flags)))
            send(WireMessage(type: "key_up", key: key, meta: modifierNames(event.flags)))
            return
        default: return
        }
        send(WireMessage(type: event.flags.contains(flag) ? "key_down" : "key_up",
                         key: key, meta: modifierNames(event.flags)))
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
    let keys: [Int64: String] = [
        0:"A", 1:"S", 2:"D", 3:"F", 4:"H", 5:"G", 6:"Z", 7:"X", 8:"C", 9:"V",
        11:"B", 12:"Q", 13:"W", 14:"E", 15:"R", 16:"Y", 17:"T", 18:"1", 19:"2",
        20:"3", 21:"4", 22:"6", 23:"5", 24:"=", 25:"9", 26:"7", 27:"-", 28:"8",
        29:"0", 30:"]", 31:"O", 32:"U", 33:"[", 34:"I", 35:"P", 36:"ENTER",
        37:"L", 38:"J", 39:"'", 40:"K", 41:";", 42:"\\", 43:",", 44:"/", 45:"N",
        46:"M", 47:".", 48:"TAB", 49:"SPACE", 50:"`", 51:"BACKSPACE", 53:"ESCAPE",
        54:"RWIN", 55:"LWIN", 56:"LSHIFT", 57:"CAPSLOCK", 58:"LALT", 59:"LCONTROL",
        60:"RSHIFT", 61:"RALT", 62:"RCONTROL", 64:"F17", 65:"DECIMAL", 67:"MULTIPLY",
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

let arguments = CommandLine.arguments
let configPath: String
if let index = arguments.firstIndex(of: "--config"), arguments.indices.contains(index + 1) {
    configPath = arguments[index + 1]
} else {
    configPath = "macbridge.json"
}

do {
    let config = try loadConfig(path: configPath)
    let prompt = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
    guard AXIsProcessTrustedWithOptions(prompt) else {
        throw NSError(domain: "MacBridge", code: 5,
                      userInfo: [NSLocalizedDescriptionKey: "Accessibility permission is required"])
    }

    let client = SocketClient()
    try client.connect(host: config.host, port: config.port, token: config.token)
    let controller = BridgeController(config: config, client: client)
    client.onMessage = { [weak controller] message in
        DispatchQueue.main.async { controller?.receive(message) }
    }
    client.onDisconnect = { [weak controller] reason in
        DispatchQueue.main.async { controller?.connectionLost(reason) }
    }
    try controller.start()
    client.startReading()

    signal(SIGINT, SIG_IGN)
    signal(SIGTERM, SIG_IGN)
    let interrupt = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
    let terminate = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
    interrupt.setEventHandler { controller.shutdown() }
    terminate.setEventHandler { controller.shutdown() }
    interrupt.resume()
    terminate.resume()

    print("macbridge: connected to \(config.host):\(config.port); move through the Mac top edge")
    CFRunLoopRun()
    controller.shutdown()
} catch {
    fputs("macbridge: \(error.localizedDescription)\n", stderr)
    exit(1)
}
