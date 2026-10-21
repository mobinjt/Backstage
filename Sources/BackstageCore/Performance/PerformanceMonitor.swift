import Foundation
import Observation
import QuartzCore
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// Frame rate, dropped frames, main-thread hangs, memory and CPU, sampled once a second while the
/// performance overlay is shown.
@MainActor
@Observable
public final class PerformanceMonitor {
    public static let shared = PerformanceMonitor()

    public struct Sample: Sendable, Identifiable {
        public var id: Date { date }
        public let date: Date
        public let framesPerSecond: Double
        /// Frames that took more than one and a half frame times in the last second.
        public let droppedFrames: Int
        public let memoryBytes: UInt64
        /// Of one core: 200 means two cores fully busy.
        public let cpuPercent: Double
    }

    /// The main thread didn't respond for a while.
    public struct Hang: Sendable, Identifiable {
        public let id = UUID()
        public let date: Date
        public let duration: TimeInterval
    }

    /// The last minute, oldest first.
    public private(set) var samples: [Sample] = []
    /// The last 20 hangs, newest first.
    public private(set) var hangs: [Hang] = []
    public private(set) var isRunning = false

    /// A hang is a main thread that answers later than this.
    public static let hangThreshold: TimeInterval = 0.25

    @ObservationIgnored private var frameCounter: FrameCounter?
    @ObservationIgnored private var sampling: Task<Void, Never>?
    @ObservationIgnored private var watchdog: HangWatchdog?

    nonisolated init() {}

    public var latest: Sample? { samples.last }

    /// The most frames a second the screen can show: 120 on ProMotion screens.
    public static var screenMaximumFramesPerSecond: Int {
        #if canImport(UIKit)
        UIApplication.shared.connectedScenes.compactMap { ($0 as? UIWindowScene)?.screen.maximumFramesPerSecond }.max() ?? 60
        #else
        NSScreen.main?.maximumFramesPerSecond ?? 60
        #endif
    }

    /// iOS holds iPhone apps to 60 fps on faster screens unless their Info.plist sets
    /// `CADisableMinimumFrameDurationOnPhone`. iPads and Macs have no such limit.
    public static var isHeldTo60FramesPerSecond: Bool {
        #if canImport(UIKit)
        UIDevice.current.userInterfaceIdiom == .phone
            && screenMaximumFramesPerSecond > 60
            && Bundle.main.object(forInfoDictionaryKey: "CADisableMinimumFrameDurationOnPhone") as? Bool != true
        #else
        false
        #endif
    }

    public func start() {
        guard !isRunning else { return }
        isRunning = true
        let counter = FrameCounter()
        counter.start()
        frameCounter = counter
        let watchdog = HangWatchdog { [weak self] duration in
            self?.record(hang: duration)
        }
        watchdog.start()
        self.watchdog = watchdog
        sampling = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                self?.sample()
            }
        }
    }

    public func stop() {
        isRunning = false
        sampling?.cancel()
        sampling = nil
        frameCounter?.stop()
        frameCounter = nil
        watchdog?.stop()
        watchdog = nil
    }

    private func sample() {
        guard let frameCounter else { return }
        let frames = frameCounter.drain()
        samples.append(Sample(
            date: .now,
            framesPerSecond: frames.perSecond,
            droppedFrames: frames.dropped,
            memoryBytes: SystemUsage.memoryFootprint(),
            cpuPercent: SystemUsage.cpuPercent()
        ))
        if samples.count > 60 {
            samples.removeFirst(samples.count - 60)
        }
    }

    private func record(hang duration: TimeInterval) {
        hangs.insert(Hang(date: .now, duration: duration), at: 0)
        if hangs.count > 20 {
            hangs.removeLast()
        }
    }
}

/// Counts frames with a display link.
@MainActor
private final class FrameCounter: NSObject {
    private var link: CADisplayLink?
    private var frames = 0
    private var dropped = 0
    private var lastTimestamp: CFTimeInterval?
    private var windowStart = CACurrentMediaTime()

    func start() {
        #if canImport(UIKit)
        let link = CADisplayLink(target: self, selector: #selector(tick(_:)))
        // Every frame the display can show, not a rate the system lowers to save power.
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 120, preferred: 120)
        #else
        guard let link = NSScreen.main?.displayLink(target: self, selector: #selector(tick(_:))) else { return }
        #endif
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    func stop() {
        link?.invalidate()
        link = nil
    }

    @objc private func tick(_ link: CADisplayLink) {
        frames += 1
        let expected = link.targetTimestamp - link.timestamp
        if let lastTimestamp, expected > 0, link.timestamp - lastTimestamp > expected * 1.5 {
            dropped += 1
        }
        lastTimestamp = link.timestamp
    }

    /// Frames per second and dropped frames since the last call.
    func drain() -> (perSecond: Double, dropped: Int) {
        let now = CACurrentMediaTime()
        let elapsed = max(now - windowStart, 0.001)
        let result = (Double(frames) / elapsed, dropped)
        frames = 0
        dropped = 0
        windowStart = now
        return result
    }
}

/// Pings the main thread from a background queue and reports when it answers late.
private final class HangWatchdog: @unchecked Sendable {
    private let queue = DispatchQueue(label: "Backstage.HangWatchdog", qos: .userInteractive)
    private var timer: DispatchSourceTimer?
    private var isWaiting = false
    private let report: @MainActor (TimeInterval) -> Void

    init(report: @escaping @MainActor (TimeInterval) -> Void) {
        self.report = report
    }

    func start() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: .milliseconds(100))
        timer.setEventHandler { [weak self] in
            self?.ping()
        }
        timer.resume()
        self.timer = timer
    }

    func stop() {
        timer?.cancel()
        timer = nil
    }

    private func ping() {
        // One ping at a time, so a long hang is reported once.
        guard !isWaiting else { return }
        isWaiting = true
        let sent = CACurrentMediaTime()
        let report = report
        DispatchQueue.main.async { [self] in
            let delay = CACurrentMediaTime() - sent
            if delay > PerformanceMonitor.hangThreshold {
                MainActor.assumeIsolated { report(delay) }
            }
            queue.async { self.isWaiting = false }
        }
    }
}

/// The app's memory footprint and CPU use, from the Mach kernel.
enum SystemUsage {
    private static var task: mach_port_t { mach_task_self_ }

    /// What the system counts against the app (the number Xcode's memory gauge shows).
    static func memoryFootprint() -> UInt64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(task, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? info.phys_footprint : 0
    }

    /// The sum of the app's threads' CPU use, in percent of one core.
    static func cpuPercent() -> Double {
        var threads: thread_act_array_t?
        var threadCount: mach_msg_type_number_t = 0
        guard task_threads(task, &threads, &threadCount) == KERN_SUCCESS, let threads else { return 0 }
        defer {
            vm_deallocate(task, vm_address_t(UInt(bitPattern: threads)), vm_size_t(Int(threadCount) * MemoryLayout<thread_t>.stride))
        }
        var total = 0.0
        for index in 0..<Int(threadCount) {
            var info = thread_basic_info()
            var count = mach_msg_type_number_t(MemoryLayout<thread_basic_info>.size / MemoryLayout<integer_t>.size)
            let result = withUnsafeMutablePointer(to: &info) { pointer in
                pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                    thread_info(threads[index], thread_flavor_t(THREAD_BASIC_INFO), $0, &count)
                }
            }
            if result == KERN_SUCCESS, info.flags & TH_FLAGS_IDLE == 0 {
                total += Double(info.cpu_usage) / Double(TH_USAGE_SCALE) * 100
            }
            mach_port_deallocate(task, threads[index])
        }
        return total
    }
}
