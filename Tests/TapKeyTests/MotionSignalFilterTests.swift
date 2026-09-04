import XCTest
@testable import TapKey

final class MotionSignalFilterTests: XCTestCase {
    func testAStableLaptopSettlesAndASuddenMoveCreatesASpike() {
        var filter = MotionSignalFilter()
        var stablePeak: Float = 0

        for _ in 0..<100 {
            if let value = filter.process(x: 0, y: 0, z: 65_536) {
                stablePeak = value
            }
        }
        let impactPeak = filter.process(x: 16_384, y: 0, z: 65_536)

        XCTAssertLessThan(stablePeak, 0.001)
        XCTAssertGreaterThan(impactPeak ?? 0, 0.02)
    }

    func testAnImpactOnASkippedSampleIsRecovered() {
        var filter = MotionSignalFilter()

        for _ in 0..<101 {
            _ = filter.process(x: 0, y: 0, z: 65_536)
        }
        XCTAssertNil(filter.process(x: 16_384, y: 0, z: 65_536))

        let recoveredPeak = filter.process(x: 0, y: 0, z: 65_536)
        XCTAssertGreaterThan(recoveredPeak ?? 0, 0.02)
    }
}
