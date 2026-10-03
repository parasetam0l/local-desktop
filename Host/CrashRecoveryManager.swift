import Foundation
import AppKit
import Darwin

/// Manages crash recovery and supervisor watchdog monitoring for LocalDesktopHost.
///
/// Architecture:
/// 1. When the host app launches, it registers POSIX signal handlers and spawns a detached
///    lightweight supervisor process (`--supervisor <pid> <bundlePath>`).
/// 2. The supervisor monitors the host's PID using a kernel event filter (`kqueue` / `NOTE_EXIT`).
/// 3. If the host terminates cleanly (Quit, `applicationWillTerminate`, or SIGTERM),
///    a clean-exit sentinel named after its PID is written, and the supervisor exits without restarting.
/// 4. If the host terminates abnormally (SIGSEGV, SIGBUS, a Swift trap, Force Quit, etc.), the
///    supervisor finds no sentinel, checks the rate-limit circuit-breaker (max 5 restarts in 60s),
///    and relaunches the app via `/usr/bin/open -n <bundlePath> --args --recovered`.
@MainActor
final class CrashRecoveryManager {
    static let shared = CrashRecoveryManager()

    /// Passed to an instance relaunched by the supervisor.
    nonisolated static let recoveredArgument = "--recovered"

    private let appSupportDir: URL
    private let crashLogFileURL: URL
    private var isStarted = false
    private var terminationSource: DispatchSourceSignal?

    private init() {
        appSupportDir = Self.appSupportDirectory()
        crashLogFileURL = appSupportDir.appendingPathComponent("crash_recovery.log")
        try? FileManager.default.createDirectory(at: appSupportDir, withIntermediateDirectories: true)
    }

    nonisolated private static func appSupportDirectory() -> URL {
        let baseDir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return baseDir.appendingPathComponent("localdesktop.host", isDirectory: true)
    }

    /// One sentinel per process, so a second copy of the app quitting can't mark
    /// the primary instance as cleanly exited.
    nonisolated private static func cleanExitURL(in dir: URL, pid: Int32) -> URL {
        dir.appendingPathComponent("clean_exit.\(pid)")
    }

    // MARK: - Main Application Lifecycle

    /// Starts supervisor watchdog and registers crash signal handlers for the host process.
    func start() {
        guard !isStarted else { return }
        isStarted = true

        // A stale sentinel from an earlier process with a recycled PID would hide a crash.
        try? FileManager.default.removeItem(at: Self.cleanExitURL(in: appSupportDir, pid: getpid()))

        Self.installSignalHandlers(logPath: crashLogFileURL.path)
        installTerminationHandler()

        if CommandLine.arguments.contains("--no-supervisor") {
            return
        }
        spawnSupervisor()
    }

    /// Marks that the process is shutting down cleanly so the supervisor will not relaunch it.
    /// A no-op in an instance that never started recovery (e.g. a duplicate that is quitting).
    func markCleanExit() {
        guard isStarted else { return }
        let timestamp = ISO8601DateFormatter().string(from: Date())
        try? timestamp.write(to: Self.cleanExitURL(in: appSupportDir, pid: getpid()), atomically: true, encoding: .utf8)
    }

    /// `kill`, `pkill`, and system shutdown send SIGTERM; treat it like Quit.
    private func installTerminationHandler() {
        signal(SIGTERM, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        source.setEventHandler {
            MainActor.assumeIsolated {
                CrashRecoveryManager.shared.markCleanExit()
                NSApplication.shared.terminate(nil)
            }
        }
        source.resume()
        terminationSource = source
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
            Self.appendLog("Failed to spawn crash supervisor: \(error.localizedDescription)", to: crashLogFileURL)
        }
    }

    // MARK: - Supervisor Mode

    /// Entry point when launched with `--supervisor <parentPID> <bundlePath>`
    nonisolated static func runSupervisorMode() {
        let args = CommandLine.arguments
        guard args.count >= 4,
              let parentPID = Int32(args[2]) else {
            return
        }
        let bundlePath = args[3]

        let appSupport = appSupportDirectory()
        let cleanExitURL = cleanExitURL(in: appSupport, pid: parentPID)
        let historyURL = appSupport.appendingPathComponent("crash_history.json")
        let logURL = appSupport.appendingPathComponent("crash_recovery.log")
        try? FileManager.default.createDirectory(at: appSupport, withIntermediateDirectories: true)

        func logSupervisor(_ msg: String) {
            appendLog("[Supervisor] \(msg)", to: logURL)
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

        logSupervisor("Circuit breaker OK (crash \(timestamps.count)/5 in 60s). Relaunching \(bundlePath)...")
        usleep(250_000)
        let openProc = Process()
        openProc.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        openProc.arguments = ["-n", bundlePath, "--args", recoveredArgument]
        try? openProc.run()
    }

    // MARK: - POSIX Signal Handlers

    // Everything the handler touches is allocated up front: a signal handler may only
    // call async-signal-safe functions, and that rules out allocating memory.
    // They are written once, before the handlers are installed, and only read afterwards.
    private static let signalMessageCapacity = 128
    nonisolated(unsafe) private static var signalLogPath: UnsafeMutablePointer<CChar>?
    nonisolated(unsafe) private static var signalMessage: UnsafeMutablePointer<UInt8>?
    nonisolated(unsafe) private static var signalPrefixLength = 0

    private static func installSignalHandlers(logPath: String) {
        signalLogPath = strdup(logPath)
        let prefix = Array("Fatal signal caught by CrashRecoveryManager: ".utf8)
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: signalMessageCapacity)
        buffer.initialize(repeating: 0, count: signalMessageCapacity)
        buffer.update(from: prefix, count: prefix.count)
        signalMessage = buffer
        signalPrefixLength = prefix.count

        var sa = sigaction()
        sa.__sigaction_u.__sa_handler = { sig in
            if let logPath = CrashRecoveryManager.signalLogPath,
               let message = CrashRecoveryManager.signalMessage {
                // Format "<prefix><signal number>\n" in place (signal numbers are < 100).
                var length = CrashRecoveryManager.signalPrefixLength
                let number = Int(sig)
                if number >= 10 {
                    message[length] = UInt8(48 + number / 10)
                    length += 1
                }
                message[length] = UInt8(48 + number % 10)
                message[length + 1] = 10
                length += 2

                let fd = open(logPath, O_WRONLY | O_CREAT | O_APPEND, 0o644)
                if fd >= 0 {
                    _ = write(fd, message, length)
                    close(fd)
                }
            }
            // Re-raise default signal handler to generate standard crash report / core dump
            signal(sig, SIG_DFL)
            raise(sig)
        }
        sigemptyset(&sa.sa_mask)
        sa.sa_flags = SA_RESETHAND

        for sig in [SIGSEGV, SIGBUS, SIGABRT, SIGILL, SIGTRAP, SIGFPE] {
            sigaction(sig, &sa, nil)
        }
    }

    nonisolated private static func appendLog(_ msg: String, to url: URL) {
        let line = "[\(ISO8601DateFormatter().string(from: Date()))] \(msg)\n"
        guard let data = line.data(using: .utf8) else { return }
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(data)
            try? handle.close()
        } else {
            try? data.write(to: url)
        }
    }
}
