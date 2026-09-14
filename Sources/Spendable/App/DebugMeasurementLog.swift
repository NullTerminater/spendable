#if DEBUG
import Foundation

/// Appends one line per measurement to `measurements.log` in the container, so the measurement
/// scripts read deterministic values instead of racing the unified log's disk flush.
/// Debug builds only. Lines carry numbers and stage names, never data.
enum DebugMeasurementLog {
    static func append(_ line: String) {
        guard let paths = try? StorePaths.live() else { return }
        let url = paths.containerURL.appendingPathComponent("measurements.log", isDirectory: false)
        let data = Data((line + "\n").utf8)
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: url)
        }
    }
}
#endif
