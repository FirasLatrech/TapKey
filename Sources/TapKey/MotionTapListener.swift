import Foundation
import IOKit
import IOKit.hid

final class MotionTapListener {
    private static let usagePage = 0xFF00
    private static let usage = 3
    private static let reportIntervalMicroseconds = 10_000

    private var manager: IOHIDManager?
    private var device: IOHIDDevice?
    private var reportBuffer: UnsafeMutablePointer<UInt8>?
    private var reportBufferSize = 0
    private var signalFilter = MotionSignalFilter()
    private var detector: TapSequenceDetector
    private var receivedFirstReport = false
    private var retriedActivation = false
    private var sequenceGeneration = 0
    private let onReady: () -> Void
    private let onFailure: (String) -> Void
    private let onGesture: (Int) -> Void

    init(
        threshold: Float,
        onReady: @escaping () -> Void,
        onFailure: @escaping (String) -> Void,
        onGesture: @escaping (Int) -> Void
    ) {
        detector = TapSequenceDetector(threshold: threshold)
        self.onReady = onReady
        self.onFailure = onFailure
        self.onGesture = onGesture
    }

    deinit {
        stop()
    }

    func setThreshold(_ threshold: Float) {
        detector.threshold = threshold
    }

    func start() throws {
        guard manager == nil else { return }

        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        let matching = [
            kIOHIDPrimaryUsagePageKey as String: Self.usagePage,
            kIOHIDPrimaryUsageKey as String: Self.usage
        ] as CFDictionary
        IOHIDManagerSetDeviceMatching(manager, matching)
        guard IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone)) == kIOReturnSuccess else {
            throw MotionTapListenerError.sensorAccessDenied
        }

        guard let devices = IOHIDManagerCopyDevices(manager),
              let device = Self.findSPUDevice(in: devices) else {
            IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
            throw MotionTapListenerError.sensorNotFound
        }

        guard IOHIDDeviceOpen(device, IOOptionBits(kIOHIDOptionsTypeNone)) == kIOReturnSuccess else {
            IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
            throw MotionTapListenerError.sensorAccessDenied
        }

        let size = IOHIDDeviceGetProperty(device, kIOHIDMaxInputReportSizeKey as CFString) as? Int ?? 0
        guard size >= 18 else {
            IOHIDDeviceClose(device, IOOptionBits(kIOHIDOptionsTypeNone))
            IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
            throw MotionTapListenerError.invalidSensor
        }

        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: size)
        buffer.initialize(repeating: 0, count: size)
        let context = Unmanaged.passUnretained(self).toOpaque()

        IOHIDDeviceRegisterInputReportCallback(
            device,
            buffer,
            size,
            { context, result, _, _, _, report, length in
                guard result == kIOReturnSuccess, let context else { return }
                Unmanaged<MotionTapListener>.fromOpaque(context)
                    .takeUnretainedValue()
                    .handleReport(report, length: length)
            },
            context
        )
        IOHIDDeviceScheduleWithRunLoop(
            device,
            CFRunLoopGetMain(),
            CFRunLoopMode.defaultMode.rawValue
        )

        self.manager = manager
        self.device = device
        reportBuffer = buffer
        reportBufferSize = size

        guard Self.setSensor(active: true) else {
            stop()
            throw MotionTapListenerError.sensorAccessDenied
        }
        checkForFirstReport()
    }

    func stop() {
        sequenceGeneration += 1
        guard let manager else { return }

        Self.setSensor(active: false)
        if let device, let reportBuffer {
            IOHIDDeviceRegisterInputReportCallback(
                device,
                reportBuffer,
                reportBufferSize,
                nil,
                nil
            )
        }
        if let device {
            IOHIDDeviceUnscheduleFromRunLoop(
                device,
                CFRunLoopGetMain(),
                CFRunLoopMode.defaultMode.rawValue
            )
            IOHIDDeviceClose(device, IOOptionBits(kIOHIDOptionsTypeNone))
        }
        IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        reportBuffer?.deallocate()

        self.manager = nil
        device = nil
        reportBuffer = nil
        reportBufferSize = 0
    }

    private func handleReport(_ report: UnsafeMutablePointer<UInt8>, length: Int) {
        guard length == 22 else { return }

        if !receivedFirstReport {
            receivedFirstReport = true
            onReady()
        }

        let bytes = UnsafeRawPointer(report)
        let x = Int32(littleEndian: bytes.loadUnaligned(fromByteOffset: 6, as: Int32.self))
        let y = Int32(littleEndian: bytes.loadUnaligned(fromByteOffset: 10, as: Int32.self))
        let z = Int32(littleEndian: bytes.loadUnaligned(fromByteOffset: 14, as: Int32.self))

        guard let peak = signalFilter.process(x: x, y: y, z: z) else { return }
        let now = ProcessInfo.processInfo.systemUptime
        let update = detector.record(peak: peak, at: now)
        guard let update else { return }

        switch update {
        case let .waiting(deadline):
            sequenceGeneration += 1
            let generation = sequenceGeneration
            DispatchQueue.main.asyncAfter(deadline: .now() + max(0, deadline - now)) { [weak self] in
                guard let self, self.sequenceGeneration == generation else { return }
                if let count = self.detector.finish(at: deadline) {
                    self.onGesture(count)
                }
            }
        case let .completed(count):
            sequenceGeneration += 1
            onGesture(count)
        }
    }

    private func checkForFirstReport() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            guard let self, self.manager != nil, !self.receivedFirstReport else { return }
            if !self.retriedActivation {
                self.retriedActivation = true
                Self.setSensor(active: true)
                self.checkForFirstReport()
            } else {
                self.onFailure("No motion reports received. Relaunch TapKey.")
            }
        }
    }

    private static func findSPUDevice(in devices: CFSet) -> IOHIDDevice? {
        let count = CFSetGetCount(devices)
        var values = [UnsafeRawPointer?](repeating: nil, count: count)
        CFSetGetValues(devices, &values)

        for value in values {
            guard let value else { continue }
            let device = Unmanaged<IOHIDDevice>.fromOpaque(value).takeUnretainedValue()
            let transport = IOHIDDeviceGetProperty(device, kIOHIDTransportKey as CFString) as? String
            if transport == "SPU" { return device }
        }
        return nil
    }

    @discardableResult
    private static func setSensor(active: Bool) -> Bool {
        guard let matching = IOServiceMatching("AppleSPUHIDDriver") else { return false }
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == KERN_SUCCESS else {
            return false
        }
        defer { IOObjectRelease(iterator) }

        var changed = false
        while case let service = IOIteratorNext(iterator), service != 0 {
            defer { IOObjectRelease(service) }
            let dispatchesAcceleration = IORegistryEntryCreateCFProperty(
                service,
                "dispatchAccel" as CFString,
                kCFAllocatorDefault,
                0
            )?.takeRetainedValue() as? Bool ?? false
            guard dispatchesAcceleration else { continue }

            let interval = active ? reportIntervalMicroseconds : 0
            let state = active ? 1 : 0
            let results = [
                IORegistryEntrySetCFProperty(service, "ReportInterval" as CFString, interval as CFNumber),
                IORegistryEntrySetCFProperty(service, "SensorPropertyReportingState" as CFString, state as CFNumber),
                IORegistryEntrySetCFProperty(service, "SensorPropertyPowerState" as CFString, state as CFNumber)
            ]
            changed = results.allSatisfy { $0 == KERN_SUCCESS }
        }
        return changed
    }
}

struct MotionSignalFilter {
    private var previous: Vector3?
    private var highPassed = Vector3.zero
    private var lowPassed = Vector3.zero
    private var sampleCount = 0
    private var processedSampleCount = 0

    mutating func process(x: Int32, y: Int32, z: Int32) -> Float? {
        let raw = Vector3(
            x: Float(x) / 65_536,
            y: Float(y) / 65_536,
            z: Float(z) / 65_536
        )
        guard raw.magnitude > 0.3, raw.magnitude < 4 else { return nil }
        guard let previous else {
            self.previous = raw
            return nil
        }

        self.previous = raw
        sampleCount += 1
        guard sampleCount.isMultiple(of: 2) else { return nil }

        let highPassAlpha: Float = 0.285
        highPassed = Vector3(
            x: highPassAlpha * (highPassed.x + raw.x - previous.x),
            y: highPassAlpha * (highPassed.y + raw.y - previous.y),
            z: highPassAlpha * (highPassed.z + raw.z - previous.z)
        )
        let lowPassAlpha: Float = 0.759
        lowPassed = Vector3(
            x: lowPassed.x + lowPassAlpha * (highPassed.x - lowPassed.x),
            y: lowPassed.y + lowPassAlpha * (highPassed.y - lowPassed.y),
            z: lowPassed.z + lowPassAlpha * (highPassed.z - lowPassed.z)
        )
        processedSampleCount += 1
        guard processedSampleCount >= 50 else { return nil }
        return lowPassed.magnitude
    }
}

private struct Vector3 {
    var x: Float
    var y: Float
    var z: Float

    var magnitude: Float { sqrtf(x * x + y * y + z * z) }
    static let zero = Vector3(x: 0, y: 0, z: 0)
}

enum MotionTapListenerError: LocalizedError {
    case sensorNotFound
    case sensorAccessDenied
    case invalidSensor

    var errorDescription: String? {
        switch self {
        case .sensorNotFound:
            "This MacBook has no supported motion sensor."
        case .sensorAccessDenied:
            "macOS blocked access to the motion sensor."
        case .invalidSensor:
            "The motion sensor returned an unknown data format."
        }
    }
}
