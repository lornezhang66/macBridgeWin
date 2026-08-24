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

    func testCrossingResetsAfterPause() {
        var crossing = CrossingAccumulator(threshold: 10, idleResetSeconds: 0.5)
        XCTAssertFalse(crossing.update(atEdge: true, outwardDelta: 6, now: 1.0))
        XCTAssertFalse(crossing.update(atEdge: true, outwardDelta: 4, now: 2.0))
        XCTAssertEqual(crossing.total, 4)
    }

    func testRatiosMapAndClamp() {
        XCTAssertEqual(clampedRatio(position: 150, origin: 100, length: 200), 0.25)
        XCTAssertEqual(clampedRatio(position: 500, origin: 100, length: 200), 1)
        XCTAssertEqual(clampedPosition(ratio: 0.5, origin: -1920, length: 1920), -960)
        XCTAssertEqual(clampedPosition(ratio: 2, origin: 0, length: 100), 99)
        XCTAssertEqual(clampedPosition(ratio: .nan, origin: 20, length: 100), 20)
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
