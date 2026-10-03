import AppKit
import Combine
import Sparkle

/// Updates from GitHub Releases with Sparkle. The feed (SUFeedURL) is the
/// appcast.xml attached to the latest published release; each update is
/// signed with the EdDSA key whose public half is SUPublicEDKey, and must
/// carry the same Developer ID signature as the running app. The host checks
/// once a day and always asks before installing (SUAllowsAutomaticUpdates is
/// off). Development builds don't check: they aren't releases.
///
/// The host lives in the menu bar with no windows of its own, so an update
/// alert that Sparkle can't show in front would end up behind other apps.
/// Instead the menu bar icon and panel show that an update is waiting
/// ("gentle reminders"), and the alert comes up when the user asks for it.
@MainActor
final class AppUpdater: NSObject, ObservableObject, SPUStandardUserDriverDelegate {
    static let shared = AppUpdater()

    /// Nil in development builds.
    private var controller: SPUStandardUpdaterController?
    @Published private(set) var canCheckForUpdates = false
    /// A version found by a scheduled check that is waiting for the user.
    @Published private(set) var pendingUpdateVersion: String?
    private var cancellables: Set<AnyCancellable> = []

    var isAvailable: Bool { controller != nil }

    var automaticallyChecksForUpdates: Bool {
        get { controller?.updater.automaticallyChecksForUpdates ?? false }
        set {
            objectWillChange.send()
            controller?.updater.automaticallyChecksForUpdates = newValue
        }
    }

    private override init() {
        super.init()
        #if !DEBUG
        controller = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: nil, userDriverDelegate: self)
        #endif
        controller?.updater.publisher(for: \.canCheckForUpdates)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] canCheck in
                MainActor.assumeIsolated {
                    self?.canCheckForUpdates = canCheck
                }
            }
            .store(in: &cancellables)
    }

    /// Starts the daily checks; only the primary instance does this.
    func start() {
        controller?.startUpdater()
    }

    func checkForUpdates() {
        // An agent app has no Dock icon; bring the update window forward.
        NSApp.activate()
        controller?.checkForUpdates(nil)
    }

    /// "1.2.0 (1791023807)"
    static var currentVersion: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "\(version) (\(build))"
    }

    // MARK: SPUStandardUserDriverDelegate (called on the main thread)

    nonisolated var supportsGentleScheduledUpdateReminders: Bool { true }

    nonisolated func standardUserDriverShouldHandleShowingScheduledUpdate(
        _ update: SUAppcastItem, andInImmediateFocus immediateFocus: Bool
    ) -> Bool {
        // Let Sparkle show the alert only when it would be in front.
        immediateFocus
    }

    nonisolated func standardUserDriverWillHandleShowingUpdate(
        _ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem, state: SPUUserUpdateState
    ) {
        let version = update.displayVersionString
        MainActor.assumeIsolated {
            if handleShowingUpdate {
                NSApp.activate()
            } else {
                pendingUpdateVersion = version
            }
        }
    }

    nonisolated func standardUserDriverDidReceiveUserAttention(forUpdate update: SUAppcastItem) {
        MainActor.assumeIsolated {
            pendingUpdateVersion = nil
        }
    }

    nonisolated func standardUserDriverWillFinishUpdateSession() {
        MainActor.assumeIsolated {
            pendingUpdateVersion = nil
        }
    }
}
