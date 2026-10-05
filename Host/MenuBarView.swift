import SwiftUI
import AppKit

/// Connects the menu bar panel to the live services.
struct MenuBarView: View {
    @EnvironmentObject private var server: HostServer
    @EnvironmentObject private var auth: AuthStore
    @EnvironmentObject private var launchManager: LaunchManager
    @ObservedObject private var updater = AppUpdater.shared

    var body: some View {
        MenuBarContent(state: state, actions: actions)
            .task {
                server.refreshPermissions()
                launchManager.refreshStatus()
                if server.screenGranted {
                    server.refreshDisplays()
                }
            }
    }

    private var state: MenuBarState {
        var state = MenuBarState()
        state.isSharing = server.running
        state.clientName = server.clientName
        if server.running, server.port > 0 {
            state.address = "\(HostServer.primaryLANAddress().map { "\($0):" } ?? "")\(server.port)"
        }
        state.computerName = server.bonjourName
        state.fingerprint = auth.identityFingerprint
        state.missingSetup = server.missingSetup
        state.failedPINAttempts = auth.lockout.failures
        state.pinLockedUntil = auth.lockout.lockedUntil
        state.lastError = server.lastError ?? server.captureError
        state.hasPIN = auth.hasPIN
        state.preset = server.preset
        state.codec = ScreenStreamer.shared.currentCodec
        state.displays = server.displays
        state.selectedDisplay = server.selectedDisplayID
        state.blocksLocalInput = server.blocksLocalInput
        state.isBlockingLocalInput = server.isBlockingLocalInput
        state.localInputBlockError = server.localInputBlockError
        state.devices = auth.devices
        state.launchAtLogin = launchManager.isEnabled
        state.launchNeedsApproval = launchManager.status == .requiresApproval
        state.launchError = launchManager.lastError
        state.appVersion = AppUpdater.currentVersion
        state.updaterAvailable = updater.isAvailable
        state.canCheckForUpdates = updater.canCheckForUpdates
        state.checksForUpdatesAutomatically = updater.automaticallyChecksForUpdates
        state.pendingUpdateVersion = updater.pendingUpdateVersion
        return state
    }

    private var actions: MenuBarActions {
        MenuBarActions(
            setSharing: { HostServer.shared.setSharing($0) },
            openSetup: { SetupWindowController.shared.show() },
            setPreset: { HostServer.shared.setPreset($0) },
            setCodec: { HostServer.shared.setCodec($0) },
            setDisplay: { HostServer.shared.setDisplay($0) },
            setBlocksLocalInput: { HostServer.shared.setBlocksLocalInput($0) },
            revoke: { AuthStore.shared.revoke(ids: [$0]) },
            changePIN: { await AuthStore.shared.setPIN($0) },
            clearLockout: { AuthStore.shared.clearLockout() },
            dismissError: {
                HostServer.shared.lastError = nil
                HostServer.shared.captureError = nil
            },
            setLaunchAtLogin: { LaunchManager.shared.setLaunchOnRestart($0) },
            openLoginItems: { LaunchManager.shared.openSystemSettings() },
            checkForUpdates: { AppUpdater.shared.checkForUpdates() },
            setChecksForUpdatesAutomatically: { AppUpdater.shared.automaticallyChecksForUpdates = $0 },
            quit: {
                CrashRecoveryManager.shared.markCleanExit()
                NSApplication.shared.terminate(nil)
            }
        )
    }
}
