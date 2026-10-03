import Foundation
import IOKit.pwr_mgt

/// Keeps the Mac and its display awake while a client is connected.
@MainActor
final class PowerAssertions {
    private var displaySleepAssertion: IOPMAssertionID = 0
    private var systemSleepAssertion: IOPMAssertionID = 0
    private var caffeinateProcess: Process?

    func acquire() {
        if displaySleepAssertion == 0 {
            IOPMAssertionCreateWithName(
                kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
                IOPMAssertionLevel(kIOPMAssertionLevelOn),
                "LocalDesktop Active Remote Session" as CFString,
                &displaySleepAssertion
            )
        }
        if systemSleepAssertion == 0 {
            IOPMAssertionCreateWithName(
                kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
                IOPMAssertionLevel(kIOPMAssertionLevelOn),
                "LocalDesktop Active Remote Session" as CFString,
                &systemSleepAssertion
            )
        }
        // caffeinate -u also declares user activity, which the IOPM assertions alone
        // don't do; it exits on its own when this process does (-w).
        if caffeinateProcess == nil || caffeinateProcess?.isRunning == false {
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/usr/bin/caffeinate")
            proc.arguments = ["-disu", "-w", "\(ProcessInfo.processInfo.processIdentifier)"]
            try? proc.run()
            caffeinateProcess = proc
        }
    }

    func release() {
        if displaySleepAssertion != 0 {
            IOPMAssertionRelease(displaySleepAssertion)
            displaySleepAssertion = 0
        }
        if systemSleepAssertion != 0 {
            IOPMAssertionRelease(systemSleepAssertion)
            systemSleepAssertion = 0
        }
        if let proc = caffeinateProcess {
            if proc.isRunning {
                proc.terminate()
            }
            caffeinateProcess = nil
        }
    }
}
