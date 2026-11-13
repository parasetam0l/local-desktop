import Foundation
import AppKit
import Darwin

/// Pure policy helpers for crash circuit-breaking and awake-time hang detection.
enum CrashRecoveryPolicy {
    static let maxCrashesInWindow = 5
    static let crashWindowSeconds: TimeInterval = 60.0
    static let heartbeatIntervalSeconds: TimeInterval = 5.0
    /// 7 missed 5s heartbeats of *awake* system uptime (`CLOCK_UPTIME_RAW`, pauses during sleep).
    static let hangTimeoutNanoseconds: UInt64 = 35_000_000_000

    static func evaluateRestart(history timestamps: [TimeInterval], now: TimeInterval) -> (allowed: Bool, updated: [TimeInterval]) {
        var recent = timestamps.filter { now - $0 < crashWindowSeconds && $0 <= now + 5.0 }
        recent.append(now)
        return (recent.count <= maxCrashesInWindow, recent)
    }

    static func isHung(lastHeartbeatUptimeNs: UInt64, currentUptimeNs: UInt64) -> Bool {
        currentUptimeNs >= lastHeartbeatUptimeNs && (currentUptimeNs - lastHeartbeatUptimeNs) >= hangTimeoutNanoseconds
    }
}

/// Manages crash recovery and hang-aware supervisor watchdog monitoring for LocalDesktop.
///
/// Architecture:
/// 1. When the host app launches, it registers POSIX signal handlers, disables App Nap
///    while awake, and spawns a detached supervisor (`--supervisor <pid> <bundlePath>`)
///    connected via a non-blocking heartbeat pipe.
/// 2. The host writes 1 byte onto the pipe every 5 s on the main runloop.
/// 3. The supervisor monitors `NOTE_EXIT`, the heartbeat pipe, and an awake-uptime
///    (`CLOCK_UPTIME_RAW`) timer inside one `kqueue` loop.
/// 4. On abnormal exit—or a confirmed main-runloop hang (excluding sleep and attached
///    debuggers)—it checks the circuit breaker (max 5 restarts in 60s) and relaunches.
@MainActor
final class CrashRecoveryManager {
    static let shared = CrashRecoveryManager()

    /// Passed to an instance relaunched by the supervisor.
    nonisolated static let recoveredArgument = "--recovered"

    private let appSupportDir: URL
    private let crashLogFileURL: URL
    private var isStarted = false
    private var terminationSource: DispatchSourceSignal?
    private var heartbeatPipe: Pipe?
    private var heartbeatTimer: Timer?
    private var activityToken: NSObjectProtocol?

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

    /// Starts supervisor watchdog, heartbeat timer, and crash signal handlers for the host process.
    func start() {
        guard !isStarted else { return }
        isStarted = true

        // A stale sentinel from an earlier process with a recycled PID would hide a crash.
        try? FileManager.default.removeItem(at: Self.cleanExitURL(in: appSupportDir, pid: getpid()))

        // Keep runloop timers responsive while the Mac is awake without blocking idle sleep.
        activityToken = ProcessInfo.processInfo.beginActivity(
            options: .userInitiatedAllowingIdleSystemSleep,
            reason: "LocalDesktop background service and watchdog heartbeat"
        )

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
        heartbeatTimer?.invalidate()
        heartbeatTimer = nil
        if let token = activityToken {
            ProcessInfo.processInfo.endActivity(token)
            activityToken = nil
        }
        let timestamp = ISO8601DateFormatter().string(from: Date())
        try? timestamp.write(to: Self.cleanExitURL(in: appSupportDir, pid: getpid()), atomically: true, encoding: .utf8)
        try? heartbeatPipe?.fileHandleForWriting.close()
        heartbeatPipe = nil
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

        let pipe = Pipe()
        let writeFD = pipe.fileHandleForWriting.fileDescriptor
        let flags = fcntl(writeFD, F_GETFL)
        if flags >= 0 {
            _ = fcntl(writeFD, F_SETFL, flags | O_NONBLOCK)
        }

        let proc = Process()
        proc.executableURL = execURL
        proc.arguments = ["--supervisor", "\(myPID)", bundlePath]
        proc.standardInput = pipe.fileHandleForReading
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice

        do {
            try proc.run()
            try? pipe.fileHandleForReading.close()
            heartbeatPipe = pipe
            startHeartbeatTimer()
        } catch {
            Self.appendLog("Failed to spawn crash supervisor: \(error.localizedDescription)", to: crashLogFileURL)
        }
    }

    private func startHeartbeatTimer() {
        heartbeatTimer?.invalidate()
        sendHeartbeatByte()
        let timer = Timer(timeInterval: CrashRecoveryPolicy.heartbeatIntervalSeconds, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.sendHeartbeatByte()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        heartbeatTimer = timer
    }

    private func sendHeartbeatByte() {
        guard let writeFD = heartbeatPipe?.fileHandleForWriting.fileDescriptor, writeFD >= 0 else { return }
        var byte: UInt8 = 0x01
        _ = Darwin.write(writeFD, &byte, 1)
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

        var st = stat()
        let hasHeartbeatPipe = fstat(STDIN_FILENO, &st) == 0 && (st.st_mode & S_IFMT) == S_IFIFO
        if hasHeartbeatPipe {
            let flags = fcntl(STDIN_FILENO, F_GETFL)
            if flags >= 0 {
                _ = fcntl(STDIN_FILENO, F_SETFL, flags | O_NONBLOCK)
            }
        }

        let kq = kqueue()
        guard kq >= 0 else { return }

        var changes: [kevent] = [
            kevent(ident: UInt(parentPID),
                   filter: Int16(EVFILT_PROC),
                   flags: UInt16(EV_ADD | EV_ENABLE | EV_ONESHOT),
                   fflags: UInt32(NOTE_EXIT),
                   data: 0,
                   udata: nil)
        ]
        if hasHeartbeatPipe {
            changes.append(
                kevent(ident: UInt(STDIN_FILENO),
                       filter: Int16(EVFILT_READ),
                       flags: UInt16(EV_ADD | EV_ENABLE),
                       fflags: 0,
                       data: 0,
                       udata: nil)
            )
            changes.append(
                kevent(ident: 1,
                       filter: Int16(EVFILT_TIMER),
                       flags: UInt16(EV_ADD | EV_ENABLE),
                       fflags: 0,
                       data: 5_000,
                       udata: nil)
            )
        }

        _ = kevent(kq, &changes, Int32(changes.count), nil, 0, nil)

        var lastHeartbeatNs = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
        var drainBuf = [UInt8](repeating: 0, count: 64)
        var hungTriggered = false

        loop: while true {
            var event = kevent()
            let n = kevent(kq, nil, 0, &event, 1, nil)
            if n <= 0 {
                if errno == EINTR { continue }
                break
            }
            if (event.flags & UInt16(EV_ERROR)) != 0 {
                break
            }
            switch event.filter {
            case Int16(EVFILT_PROC):
                break loop
            case Int16(EVFILT_READ):
                while Darwin.read(STDIN_FILENO, &drainBuf, drainBuf.count) > 0 {
                    lastHeartbeatNs = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
                }
                if (event.flags & UInt16(EV_EOF)) != 0 {
                    // Parent closed the pipe; wait briefly for NOTE_EXIT.
                    var ts = timespec(tv_sec: 1, tv_nsec: 0)
                    var exitEv = kevent()
                    _ = kevent(kq, nil, 0, &exitEv, 1, &ts)
                    break loop
                }
            case Int16(EVFILT_TIMER):
                if FileManager.default.fileExists(atPath: cleanExitURL.path) {
                    break loop
                }
                let nowNs = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
                if CrashRecoveryPolicy.isHung(lastHeartbeatUptimeNs: lastHeartbeatNs, currentUptimeNs: nowNs) {
                    if isProcessTraced(pid: parentPID) {
                        lastHeartbeatNs = nowNs
                        continue
                    }
                    hungTriggered = true
                    logSupervisor("Hang detected for parent process \(parentPID) (no heartbeat for 35s awake time). Sending SIGABRT...")
                    kill(parentPID, SIGABRT)
                    var ts = timespec(tv_sec: 2, tv_nsec: 0)
                    var exitEv = kevent()
                    _ = kevent(kq, nil, 0, &exitEv, 1, &ts)
                    if kill(parentPID, 0) == 0 {
                        kill(parentPID, SIGKILL)
                        usleep(100_000)
                    }
                    break loop
                }
            default:
                break
            }
        }
        close(kq)

        // Give the file system a moment (150ms) to settle any write from applicationWillTerminate
        usleep(150_000)

        // Check whether a clean exit occurred
        if FileManager.default.fileExists(atPath: cleanExitURL.path) {
            try? FileManager.default.removeItem(at: cleanExitURL)
            logSupervisor("Parent process \(parentPID) exited cleanly. Supervisor stopping.")
            return
        }

        // Abnormal termination or confirmed hang detected! Check circuit-breaker
        logSupervisor("\(hungTriggered ? "Hang" : "Abnormal exit") detected for parent process \(parentPID). Checking crash circuit breaker...")

        var timestamps: [Double] = []
        if let data = try? Data(contentsOf: historyURL),
           let list = try? JSONDecoder().decode([Double].self, from: data) {
            timestamps = list
        }

        let decision = CrashRecoveryPolicy.evaluateRestart(history: timestamps, now: Date().timeIntervalSince1970)
        if let encoded = try? JSONEncoder().encode(decision.updated) {
            try? encoded.write(to: historyURL)
        }

        if !decision.allowed {
            logSupervisor("Crash loop detected (\(decision.updated.count) crashes within 60s). Pausing auto-relaunch.")
            return
        }

        logSupervisor("Circuit breaker OK (crash \(decision.updated.count)/\(CrashRecoveryPolicy.maxCrashesInWindow) in 60s). Relaunching \(bundlePath)...")
        usleep(250_000)
        let openProc = Process()
        openProc.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        openProc.arguments = ["-n", bundlePath, "--args", recoveredArgument]
        try? openProc.run()
    }

    nonisolated private static func isProcessTraced(pid: Int32) -> Bool {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.size
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, UInt32(mib.count), &info, &size, nil, 0) == 0, size > 0 else {
            return false
        }
        return (info.kp_proc.p_flag & P_TRACED) != 0
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
