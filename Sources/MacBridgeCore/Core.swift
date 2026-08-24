import Foundation

public struct MacConfig: Codable, Equatable {
    public let host: String
    public let port: Int
    public let token: String
    public let pcSide: String
    public let edgeThreshold: Double
    public let crossingThreshold: Double
    public let returnThreshold: Double
    public let sensitivity: Double
    public let scrollScale: Double

    public init(host: String, port: Int, token: String, pcSide: String = "top",
                edgeThreshold: Double, crossingThreshold: Double, returnThreshold: Double,
                sensitivity: Double, scrollScale: Double) {
        self.host = host
        self.port = port
        self.token = token
        self.pcSide = pcSide
        self.edgeThreshold = edgeThreshold
        self.crossingThreshold = crossingThreshold
        self.returnThreshold = returnThreshold
        self.sensitivity = sensitivity
        self.scrollScale = scrollScale
    }

    public func validate() throws {
        guard !host.isEmpty else { throw ConfigError.invalid("host 不能为空") }
        guard (1...65535).contains(port) else { throw ConfigError.invalid("port 必须在 1 到 65535 之间") }
        guard !token.isEmpty && token != "change-me" else { throw ConfigError.invalid("请设置非默认 token") }
        guard pcSide == "top" else { throw ConfigError.invalid("pcSide 必须为 top") }
        let numbers = [edgeThreshold, crossingThreshold, returnThreshold, sensitivity, scrollScale]
        guard numbers.allSatisfy(\.isFinite), (0...100).contains(edgeThreshold),
              (1...1_000).contains(crossingThreshold), (1...1_000).contains(returnThreshold),
              (0.05...10).contains(sensitivity), (0.05...10).contains(scrollScale) else {
            throw ConfigError.invalid("阈值或倍率超出允许范围")
        }
    }

    public enum ConfigError: LocalizedError {
        case invalid(String)
        public var errorDescription: String? {
            if case .invalid(let message) = self { return message }
            return nil
        }
    }
}

public enum BridgeMode: Equatable {
    case macActive
    case pcActive
}

public struct BridgeState {
    public private(set) var mode: BridgeMode = .macActive
    public init() {}

    @discardableResult public mutating func enterPC() -> Bool {
        guard mode == .macActive else { return false }
        mode = .pcActive
        return true
    }

    @discardableResult public mutating func returnToMac() -> Bool {
        guard mode == .pcActive else { return false }
        mode = .macActive
        return true
    }
}

public struct CrossingAccumulator {
    public let threshold: Double
    public let idleResetSeconds: TimeInterval
    public private(set) var total: Double = 0
    private var lastUpdate: TimeInterval?

    public init(threshold: Double, idleResetSeconds: TimeInterval = 0.5) {
        self.threshold = threshold
        self.idleResetSeconds = idleResetSeconds
    }

    /// Pass a positive logical outward delta. Zero/negative, leaving the edge, or pausing resets intent.
    public mutating func update(atEdge: Bool, outwardDelta: Double, now: TimeInterval) -> Bool {
        guard threshold.isFinite, threshold > 0, idleResetSeconds.isFinite, idleResetSeconds >= 0,
              outwardDelta.isFinite, now.isFinite else {
            reset()
            return false
        }
        if !atEdge || outwardDelta <= 0 || lastUpdate.map({ now < $0 || now - $0 > idleResetSeconds }) == true {
            total = 0
        }
        guard atEdge, outwardDelta > 0 else {
            lastUpdate = nil
            return false
        }
        total = min(threshold, total + outwardDelta)
        lastUpdate = now
        if total >= threshold {
            reset()
            return true
        }
        return false
    }

    public mutating func reset() {
        total = 0
        lastUpdate = nil
    }
}

public func clampedRatio(position: Double, origin: Double, length: Double) -> Double {
    guard position.isFinite, origin.isFinite, length.isFinite, length > 0 else { return 0 }
    return min(1, max(0, (position - origin) / length))
}

public func clampedPosition(ratio: Double, origin: Double, length: Double, farInset: Double = 1) -> Double {
    guard origin.isFinite, length.isFinite, length > 0 else { return origin.isFinite ? origin : 0 }
    let safeRatio = ratio.isFinite ? min(1, max(0, ratio)) : 0
    let inset = farInset.isFinite ? min(length, max(0, farInset)) : 1
    return min(origin + length - inset, origin + length * safeRatio)
}

public func sanitizedDelta(_ value: Double, scale: Double, limit: Double = 1_000) -> Double {
    guard value.isFinite, scale.isFinite, limit.isFinite, scale > 0, limit > 0 else { return 0 }
    return min(limit, max(-limit, value * scale))
}

public struct DeltaAccumulator {
    public private(set) var dx: Double = 0
    public private(set) var dy: Double = 0
    public init() {}

    public mutating func add(dx: Double, dy: Double, limit: Double = 10_000) {
        guard dx.isFinite, dy.isFinite, limit.isFinite, limit > 0 else { return }
        self.dx = min(limit, max(-limit, self.dx + dx))
        self.dy = min(limit, max(-limit, self.dy + dy))
    }

    public mutating func drain() -> (dx: Double, dy: Double)? {
        guard dx != 0 || dy != 0 else { return nil }
        defer { dx = 0; dy = 0 }
        return (dx, dy)
    }

    public mutating func reset() { dx = 0; dy = 0 }
}

public struct WireMessage: Codable, Equatable {
    public var type: String
    public var token: String?
    public var xRatio: Double?
    public var dx: Double?
    public var dy: Double?
    public var button: String?
    public var key: String?
    public var meta: [String]?

    public init(type: String, token: String? = nil, xRatio: Double? = nil,
                dx: Double? = nil, dy: Double? = nil, button: String? = nil,
                key: String? = nil, meta: [String]? = nil) {
        self.type = type
        self.token = token
        self.xRatio = xRatio
        self.dx = dx
        self.dy = dy
        self.button = button
        self.key = key
        self.meta = meta
    }
}
