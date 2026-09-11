import Foundation
import Darwin

/// Manages crash recovery and supervisor watchdog monitoring for LocalDesktopHost.
///
/// Architecture:
/// 1. When the host app launches, it registers POSIX signal handlers and spawns a detached
///    lightweight supervisor process (`--supervisor <pid> <bundlePath>`).
/// 2. The supervisor monitors the host's PID using a kernel event filter (`kqueue` / `NOTE_EXIT`).
/// 3. If the host terminates cleanly (user clicks "Quit" or `applicationWillTerminate` fires),
///    a clean-exit sentinel file is written, and the supervisor exits without restarting.
/// 4. If the host terminates abnormally (SIGSEGV, SIGBUS, etc.), the supervisor detects the
///    absence of the clean-exit sentinel, verifies the rate-limit circuit-breaker (max 5 restarts in 60s),
///    and relaunches the app via `/usr/bin/open -n <bundlePath>`.
final class CrashRecoveryManager {
    static let shared = CrashRecoveryManager()

    private let appSupportDir: URL
    private let cleanExitFileURL: URL
    private let crashHistoryFileURL: URL
    private let crashLogFileURL: URL
    private var isStarted = false

    private init() {
        let baseDir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        self.appSupportDir = baseDir.appendingPathComponent("localdesktop.host", isDirectory: true)
        self.cleanExitFileURL = appSupportDir.appendingPathComponent("clean_exit")
        self.crashHistoryFileURL = appSupportDir.appendingPathComponent("crash_history.json")
        self.crashLogFileURL = appSupportDir.appendingPathComponent("crash_recovery.log")
        try? FileManager.default.createDirectory(at: appSupportDir, withIntermediateDirectories: true)
    }

    // MARK: - Main Application Lifecycle

    /// Starts supervisor watchdog and registers crash signal handlers for the host process.
    func start() {
        guard !isStarted else { return }
        isStarted = true

        // Remove any stale clean-exit marker from previous runs
        try? FileManager.default.removeItem(at: cleanExitFileURL)

        // Install crash signal handlers
        Self.installSignalHandlers(cleanExitPath: cleanExitFileURL.path, logPath: crashLogFileURL.path)

        // Do not spawn supervisor if explicitly disabled via flag or already running under supervisor
        if CommandLine.arguments.contains("--no-supervisor") || CommandLine.arguments.contains("--supervisor") {
            return
        }

        spawnSupervisor()
    }

    /// Marks that the process is shutting down cleanly so the supervisor will not relaunch it.
    func markCleanExit() {
        let timestamp = ISO8601DateFormatter().string(from: Date())
        try? timestamp.write(to: cleanExitFileURL, atomically: true, encoding: .utf8)
    }

    private func spawnSupervisor() {
        let myPID = ProcessInfo.processInfo.processIdentifier
        let bundlePath = Bundle.main.bundlePath
        let execURL = Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0])

        let proc = Process()
        proc.executableURL = execURL
        proc.arguments = ["--supervisor", "\(myPID)", bundlePath]
        proc.standardInput = FileHandle.nullDevice
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice

        do {
            try proc.run()
        } catch {
            logMessage("Failed to spawn crash supervisor: \(error.localizedDescription)")
        }
    }

    // MARK: - Supervisor Mode

    /// Entry point when launched with `--supervisor <parentPID> <bundlePath>`
    static func runSupervisorMode() {
        let args = CommandLine.arguments
        guard args.count >= 4,
              let parentPID = Int32(args[2]) else {
            return
        }
        let bundlePath = args[3]

        let baseDir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        let appSupport = baseDir.appendingPathComponent("localdesktop.host", isDirectory: true)
        let cleanExitURL = appSupport.appendingPathComponent("clean_exit")
        let historyURL = appSupport.appendingPathComponent("crash_history.json")
        let logURL = appSupport.appendingPathComponent("crash_recovery.log")
        try? FileManager.default.createDirectory(at: appSupport, withIntermediateDirectories: true)

        func logSupervisor(_ msg: String) {
            let line = "[\(ISO8601DateFormatter().string(from: Date()))] [Supervisor] \(msg)\n"
            fputs(line, stderr)
            if let data = line.data(using: .utf8) {
                if FileManager.default.fileExists(atPath: logURL.path) {
                    if let handle = try? FileHandle(forWritingTo: logURL) {
                        handle.seekToEndOfFile()
                        handle.write(data)
                        try? handle.close()
                    }
                } else {
                    try? data.write(to: logURL)
                }
            }
        }

        // Wait for the parent process to exit using kqueue
        let kq = kqueue()
        guard kq >= 0 else { return }

        var ke = kevent(
            ident: UInt(parentPID),
            filter: Int16(EVFILT_PROC),
            flags: UInt16(EV_ADD | EV_ENABLE | EV_ONESHOT),
            fflags: UInt32(NOTE_EXIT),
            data: 0,
            udata: nil
        )

        var event = kevent()
        _ = kevent(kq, &ke, 1, &event, 1, nil)
        close(kq)

        // Give the file system a moment (150ms) to settle any write from applicationWillTerminate
        usleep(150_000)

        // Check whether a clean exit occurred
        if FileManager.default.fileExists(atPath: cleanExitURL.path) {
            // Clean exit by user or intentional shutdown
            try? FileManager.default.removeItem(at: cleanExitURL)
            logSupervisor("Parent process \(parentPID) exited cleanly. Supervisor stopping.")
            return
        }

        // Abnormal termination detected! Check circuit-breaker
        logSupervisor("Abnormal exit detected for parent process \(parentPID). Checking crash circuit breaker...")

        var timestamps: [Double] = []
        if let data = try? Data(contentsOf: historyURL),
           let list = try? JSONDecoder().decode([Double].self, from: data) {
            timestamps = list
        }

        let now = Date().timeIntervalSince1970
        // Retain only events from the last 60 seconds
        timestamps = timestamps.filter { now - $0 < 60.0 }
        timestamps.append(now)

        if let encoded = try? JSONEncoder().encode(timestamps) {
            try? encoded.write(to: historyURL)
        }

        if timestamps.count > 5 {
            logSupervisor("Crash loop detected (\(timestamps.count) crashes within 60s). Pausing auto-relaunch.")
            return
        }

        // Relaunch the application via /usr/bin/open -n <bundlePath>
        logSupervisor("Circuit breaker OK (crash \(timestamps.count)/5 in 60s). Relaunching \(bundlePath)...")
        usleep(250_000)
        let openProc = Process()
        openProc.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        openProc.arguments = ["-n", bundlePath]
        try? openProc.run()
    }

    // MARK: - POSIX Signal Handlers

    private static var signalCleanExitPath: UnsafeMutablePointer<CChar>?
    private static var signalLogPath: UnsafeMutablePointer<CChar>?

    private static func installSignalHandlers(cleanExitPath: String, logPath: String) {
        signalCleanExitPath = strdup(cleanExitPath)
        signalLogPath = strdup(logPath)

        var sa = sigaction()
        sa.__sigaction_u.__sa_handler = { sig in
            // Async-signal-safe crash handler
            if let path = CrashRecoveryManager.signalCleanExitPath {
                unlink(path)
            }
            if let logPath = CrashRecoveryManager.signalLogPath {
                let fd = open(logPath, O_WRONLY | O_CREAT | O_APPEND, 0o644)
                if fd >= 0 {
                    let msg = "Fatal signal caught by CrashRecoveryManager: "
                    write(fd, msg, msg.utf8.count)
                    var sigNumStr = String(sig) + "\n"
                    sigNumStr.withCString { ptr in
                        write(fd, ptr, strlen(ptr))
                    }
                    close(fd)
                }
            }
            // Re-raise default signal handler to generate standard crash report / core dump
            signal(sig, SIG_DFL)
            raise(sig)
        }
        sigemptyset(&sa.sa_mask)
        sa.sa_flags = SA_RESETHAND

        sigaction(SIGSEGV, &sa, nil)
        sigaction(SIGBUS, &sa, nil)
        sigaction(SIGABRT, &sa, nil)
        sigaction(SIGILL, &sa, nil)
    }

    private func logMessage(_ msg: String) {
        let line = "[\(ISO8601DateFormatter().string(from: Date()))] \(msg)\n"
        if let data = line.data(using: .utf8) {
            if FileManager.default.fileExists(atPath: crashLogFileURL.path) {
                if let handle = try? FileHandle(forWritingTo: crashLogFileURL) {
                    handle.seekToEndOfFile()
                    handle.write(data)
                    try? handle.close()
                }
            } else {
                try? data.write(to: crashLogFileURL)
            }
        }
    }
}
