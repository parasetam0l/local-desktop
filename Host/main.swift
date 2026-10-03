import Foundation
import SwiftUI

if CommandLine.arguments.contains("--supervisor") {
    CrashRecoveryManager.runSupervisorMode()
    exit(0)
}

LocalDesktopApp.main()
