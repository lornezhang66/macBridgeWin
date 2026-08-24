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
        guard numbers.allSatisfy(\.isFinite), edgeThreshold >= 0, crossingThreshold > 0,
              returnThreshold > 0, sensitivity > 0, scrollScale > 0 else {
            throw ConfigError.invalid("阈值和倍率必须是有效的正数")
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
        if !atEdge || outwardDelta <= 0 || lastUpdate.map({ now - $0 > idleResetSeconds }) == true {
            total = 0
        }
        guard atEdge, outwardDelta > 0 else {
            lastUpdate = nil
            return false
        }
        total += outwardDelta
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
    guard length > 0 else { return 0 }
    return min(1, max(0, (position - origin) / length))
}

public func clampedPosition(ratio: Double, origin: Double, length: Double, farInset: Double = 1) -> Double {
    guard length > 0 else { return origin }
    let safeRatio = ratio.isFinite ? min(1, max(0, ratio)) : 0
    return min(origin + max(0, length - farInset), origin + length * safeRatio)
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
