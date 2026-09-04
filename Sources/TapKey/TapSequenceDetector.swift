import Foundation

enum TapSequenceUpdate: Equatable {
    case waiting(until: TimeInterval)
    case completed(Int)
}

struct TapSequenceDetector {
    var threshold: Float
    var minimumGap = 0.16
    var maximumGap = 0.65
    var cooldown = 1.0

    private var tapCount = 0
    private var lastTap: TimeInterval?
    private var lastSignal = -TimeInterval.infinity
    private var lastTrigger = -TimeInterval.infinity
    private var quietSince: TimeInterval?
    private var isArmed = true

    init(threshold: Float) {
        self.threshold = threshold
    }

    mutating func record(peak: Float, at time: TimeInterval) -> TapSequenceUpdate? {
        if peak < threshold * 0.5 {
            quietSince = quietSince ?? time
            if time - quietSince! >= 0.06 { isArmed = true }
            return nil
        }

        guard peak >= threshold, isArmed, time - lastSignal >= minimumGap else { return nil }
        isArmed = false
        quietSince = nil
        lastSignal = time

        guard time - lastTrigger >= cooldown else {
            tapCount = 0
            lastTap = nil
            return nil
        }

        if let lastTap, time - lastTap > maximumGap {
            tapCount = 0
        }

        tapCount += 1
        lastTap = time

        if tapCount == 3 {
            tapCount = 0
            lastTap = nil
            lastTrigger = time
            return .completed(3)
        }

        return .waiting(until: time + maximumGap)
    }

    mutating func finish(at time: TimeInterval) -> Int? {
        guard tapCount > 0, let lastTap, time >= lastTap + maximumGap else { return nil }
        let completedCount = tapCount
        tapCount = 0
        self.lastTap = nil
        lastTrigger = lastTap
        return completedCount
    }
}
