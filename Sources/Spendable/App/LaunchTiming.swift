import Darwin
import Foundation
import os

/// Measures cold-launch time from process start (the kernel's `p_starttime`, which includes dyld
/// and Swift runtime start-up) to the moment the menu bar item is on screen. Logged once, as a
/// number only, so `scripts/measure-launch.sh` can read it from the unified log.
enum LaunchTiming {
    private static let log = Logger(subsystem: StorePaths.bundleIdentifier, category: "launch")

    /// Called from the menu bar label's `onAppear`. Second and later calls are ignored.
    @MainActor
    static func markStatusItemVisible() {
        guard !marked else { return }
        marked = true
        guard let start = processStartDate() else {
            log.notice("status item visible; process start time unavailable")
            return
        }
        let milliseconds = Int((Date().timeIntervalSince(start) * 1000).rounded())
        log.notice("status item visible after \(milliseconds, privacy: .public) ms")
        #if DEBUG
        DebugMeasurementLog.append("launch-to-bar \(milliseconds) ms")
        #endif
    }

    @MainActor private static var marked = false

    /// The process start time as recorded by the kernel.
    static func processStartDate() -> Date? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        guard sysctl(&mib, UInt32(mib.count), &info, &size, nil, 0) == 0 else { return nil }
        let started = info.kp_proc.p_starttime
        return Date(timeIntervalSince1970: TimeInterval(started.tv_sec) + TimeInterval(started.tv_usec) / 1_000_000)
    }
}
