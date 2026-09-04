import XCTest
@testable import TapKey

final class TapSequenceDetectorTests: XCTestCase {
    func testOneTapFinishesAfterMaximumGap() {
        var detector = TapSequenceDetector(threshold: 0.2)

        let deadline = waitingDeadline(detector.record(peak: 0.8, at: 1.0), expected: 1.65)
        XCTAssertNil(detector.finish(at: deadline - 0.01))
        XCTAssertEqual(detector.finish(at: deadline), 1)
    }

    func testTwoTapsFinishAfterMaximumGap() {
        var detector = TapSequenceDetector(threshold: 0.2)

        waitingDeadline(detector.record(peak: 0.8, at: 1.0), expected: 1.65)
        rearm(&detector, at: 1.1)
        let deadline = waitingDeadline(detector.record(peak: 0.8, at: 1.3), expected: 1.95)
        XCTAssertEqual(detector.finish(at: deadline), 2)
    }

    func testThreeTapsCompleteImmediately() {
        var detector = TapSequenceDetector(threshold: 0.2)

        waitingDeadline(detector.record(peak: 0.8, at: 1.0), expected: 1.65)
        rearm(&detector, at: 1.1)
        waitingDeadline(detector.record(peak: 0.8, at: 1.3), expected: 1.95)
        rearm(&detector, at: 1.4)
        XCTAssertEqual(detector.record(peak: 0.8, at: 1.6), .completed(3))
        XCTAssertNil(detector.finish(at: 3.0))
    }

    func testOneLongVibrationIsOnlyOneTap() {
        var detector = TapSequenceDetector(threshold: 0.2)

        XCTAssertNotNil(detector.record(peak: 0.8, at: 1.0))
        XCTAssertNil(detector.record(peak: 0.7, at: 1.2))
        XCTAssertNil(detector.record(peak: 0.6, at: 1.4))
        XCTAssertNil(detector.record(peak: 0.5, at: 1.6))
        XCTAssertEqual(detector.finish(at: 1.65), 1)
    }

    private func rearm(_ detector: inout TapSequenceDetector, at time: TimeInterval) {
        XCTAssertNil(detector.record(peak: 0.05, at: time))
        XCTAssertNil(detector.record(peak: 0.05, at: time + 0.07))
    }

    @discardableResult
    private func waitingDeadline(
        _ update: TapSequenceUpdate?,
        expected: TimeInterval
    ) -> TimeInterval {
        guard case let .waiting(deadline) = update else {
            XCTFail("Expected a pending tap sequence")
            return expected
        }
        XCTAssertEqual(deadline, expected, accuracy: 0.000_001)
        return deadline
    }
}
