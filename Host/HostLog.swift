import CoreGraphics
import Foundation

/// A small event log for things that can't be watched while they happen, such as what
/// the displays do when the lid closes: `~/Library/Logs/LocalDesktop/events.log`.
/// It holds no screen content, keystrokes or addresses, and starts over at about 256 KB.
enum HostLog {
    private static let queue = DispatchQueue(label: "rd.host-log", qos: .utility)
    private static let maxSize: UInt64 = 256 * 1024
    private static let url: URL = {
        let directory = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs/LocalDesktop", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("events.log")
    }()

    static func write(_ message: @autoclosure () -> String) {
        let line = "\(ISO8601DateFormatter().string(from: Date())) \(message())\n"
        queue.async {
            let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? UInt64) ?? 0
            if size > maxSize { try? FileManager.default.removeItem(at: url) }
            if let handle = try? FileHandle(forWritingTo: url) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: Data(line.utf8))
            } else {
                try? Data(line.utf8).write(to: url)
            }
        }
    }

    /// The displays as CoreGraphics sees them, in one line.
    static func displaySummary() -> String {
        var count: UInt32 = 0
        var ids = [CGDirectDisplayID](repeating: 0, count: 8)
        CGGetOnlineDisplayList(8, &ids, &count)
        let parts = ids.prefix(Int(count)).map { id -> String in
            let bounds = CGDisplayBounds(id)
            return "\(id)\(CGDisplayIsBuiltin(id) != 0 ? "B" : "")"
                + "[\(Int(bounds.width))x\(Int(bounds.height)) active=\(CGDisplayIsActive(id)) asleep=\(CGDisplayIsAsleep(id))"
                + " mirrors=\(CGDisplayMirrorsDisplay(id))]"
        }
        return "main=\(CGMainDisplayID()) " + parts.joined(separator: " ")
    }
}
