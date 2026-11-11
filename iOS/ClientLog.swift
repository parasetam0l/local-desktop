import Foundation

/// A small log in the app's Documents folder (`client.log`, last 256 KB), for
/// connection problems that only show on a device. Read it over USB with
/// `xcrun devicectl device copy from --domain-type appDataContainer
/// --domain-identifier localdesktop.client --source Documents/client.log`.
enum ClientLog {
    private static let queue = DispatchQueue(label: "rd.client-log", qos: .utility)
    private static let maxSize: UInt64 = 256 * 1024
    #if os(iOS)
    private static let url: URL? = FileManager.default
        .urls(for: .documentDirectory, in: .userDomainMask).first?
        .appendingPathComponent("client.log")
    #else
    // The Mac tests build this file too; keep their log out of the user's Documents.
    private static let url: URL? = FileManager.default.temporaryDirectory
        .appendingPathComponent("localdesktop-client-test.log")
    #endif

    static func write(_ message: @autoclosure () -> String) {
        let line = "\(ISO8601DateFormatter().string(from: Date())) \(message())\n"
        queue.async {
            guard let url, let data = line.data(using: .utf8) else { return }
            let manager = FileManager.default
            if let size = (try? manager.attributesOfItem(atPath: url.path)[.size] as? UInt64), size > maxSize {
                try? manager.removeItem(at: url)
            }
            if let handle = try? FileHandle(forWritingTo: url) {
                handle.seekToEndOfFile()
                handle.write(data)
                try? handle.close()
            } else {
                try? data.write(to: url)
            }
        }
    }
}
