import Foundation
import XCTest
@testable import MacBridgeCore

final class CoreTests: XCTestCase {
    func testStateTransitionsAreExplicitAndIdempotent() {
        var state = BridgeState()
        XCTAssertEqual(state.mode, .macActive)
        XCTAssertTrue(state.enterPC())
        XCTAssertFalse(state.enterPC())
        XCTAssertTrue(state.returnToMac())
        XCTAssertFalse(state.returnToMac())
    }

    func testCrossingNeedsContinuousOutwardMotionAtEdge() {
        var crossing = CrossingAccumulator(threshold: 10)
        XCTAssertFalse(crossing.update(atEdge: true, outwardDelta: 4, now: 1.0))
        XCTAssertFalse(crossing.update(atEdge: true, outwardDelta: 5, now: 1.1))
        XCTAssertTrue(crossing.update(atEdge: true, outwardDelta: 1, now: 1.2))

        XCTAssertFalse(crossing.update(atEdge: true, outwardDelta: 6, now: 2.0))
        XCTAssertFalse(crossing.update(atEdge: true, outwardDelta: -1, now: 2.1))
        XCTAssertFalse(crossing.update(atEdge: true, outwardDelta: 5, now: 2.2))
        XCTAssertFalse(crossing.update(atEdge: false, outwardDelta: 5, now: 2.3))
        XCTAssertFalse(crossing.update(atEdge: true, outwardDelta: 6, now: 2.4))
    }

    func testCrossingResetsAfterPauseAndInvalidInput() {
        var crossing = CrossingAccumulator(threshold: 10, idleResetSeconds: 0.5)
        XCTAssertFalse(crossing.update(atEdge: true, outwardDelta: 6, now: 1.0))
        XCTAssertFalse(crossing.update(atEdge: true, outwardDelta: 4, now: 2.0))
        XCTAssertEqual(crossing.total, 4)
        XCTAssertFalse(crossing.update(atEdge: true, outwardDelta: .nan, now: 2.1))
        XCTAssertEqual(crossing.total, 0)
        XCTAssertFalse(crossing.update(atEdge: true, outwardDelta: 6, now: 3.0))
        XCTAssertFalse(crossing.update(atEdge: true, outwardDelta: 6, now: 2.9))
        XCTAssertEqual(crossing.total, 6)
    }

    func testRatiosMapAndClamp() {
        XCTAssertEqual(clampedRatio(position: 150, origin: 100, length: 200), 0.25)
        XCTAssertEqual(clampedRatio(position: 500, origin: 100, length: 200), 1)
        XCTAssertEqual(clampedPosition(ratio: 0.5, origin: -1920, length: 1920), -960)
        XCTAssertEqual(clampedPosition(ratio: 2, origin: 0, length: 100), 99)
        XCTAssertEqual(clampedPosition(ratio: .nan, origin: 20, length: 100), 20)
        XCTAssertEqual(clampedRatio(position: .nan, origin: 0, length: 100), 0)
        XCTAssertEqual(clampedPosition(ratio: 0.5, origin: .infinity, length: 100), 0)
    }

    func testDeltasAreFiniteBoundedAndCoalesced() {
        XCTAssertEqual(sanitizedDelta(.nan, scale: 1), 0)
        XCTAssertEqual(sanitizedDelta(100, scale: 20), 1_000)
        var deltas = DeltaAccumulator()
        deltas.add(dx: 8_000, dy: -8_000)
        deltas.add(dx: 8_000, dy: -8_000)
        let drained = deltas.drain()
        XCTAssertEqual(drained?.dx, 10_000)
        XCTAssertEqual(drained?.dy, -10_000)
        XCTAssertNil(deltas.drain())
        deltas.add(dx: .nan, dy: 1)
        XCTAssertNil(deltas.drain())
    }

    func testConfigRejectsExtremePhysicalTuning() {
        let config = MacConfig(host: "127.0.0.1", port: 24800, token: "long-token",
                               edgeThreshold: 2, crossingThreshold: 10, returnThreshold: 10,
                               sensitivity: .infinity, scrollScale: 1)
        XCTAssertThrowsError(try config.validate())
    }

    func testProtocolIsJSONLinesCompatible() throws {
        let message = WireMessage(type: "enter_pc", xRatio: 0.42)
        let data = try JSONEncoder().encode(message)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(object["type"] as? String, "enter_pc")
        XCTAssertEqual(object["xRatio"] as? Double, 0.42)
        XCTAssertNil(object["token"])
        XCTAssertEqual(try JSONDecoder().decode(WireMessage.self, from: data), message)
    }
}
