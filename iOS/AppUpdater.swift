import Foundation
import Combine
#if canImport(UIKit)
import UIKit
#endif

/// Offers newer releases of this app. Releases are Ad Hoc builds installed over the
/// air from the install page on GitHub Pages; its `manifest.plist` (the file iOS
/// installs from) names the latest published version. See docs/RELEASING.md.
@MainActor
final class AppUpdater: ObservableObject {
    /// The latest version, when the last check found one newer than this app.
    @Published private(set) var availableVersion: String?
    @Published private(set) var isChecking = false
    @Published private(set) var lastCheckFailed = false
    /// The install was handed to iOS, which replaces this app only once it has left the
    /// foreground; until then the banner asks to close the app.
    @Published private(set) var isAwaitingInstall = false
    @Published private var dismissedVersion: String? {
        didSet { UserDefaults.standard.set(dismissedVersion, forKey: Self.dismissedKey) }
    }

    nonisolated static let currentVersion =
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"

    /// Automatic checks run at most this often; checking by hand always does.
    private static let checkInterval: TimeInterval = 6 * 60 * 60
    private static let dismissedKey = "rd.dismissedUpdate"

    private let manifestURL = (Bundle.main.object(forInfoDictionaryKey: "LDUpdateManifestURL") as? String)
        .flatMap(URL.init(string:))
    private let releasesURL = Bundle.main.object(forInfoDictionaryKey: "LDReleasesURL") as? String
    private var lastCheck: Date?

    init() {
        dismissedVersion = UserDefaults.standard.string(forKey: Self.dismissedKey)
    }

    /// The version to show a banner for: newer, and not dismissed.
    var bannerVersion: String? {
        guard let availableVersion, availableVersion != dismissedVersion else { return nil }
        return availableVersion
    }

    /// Opening this asks iOS to install the latest release over this one.
    private var installURL: URL? {
        manifestURL.flatMap { URL(string: "itms-services://?action=download-manifest&url=\($0.absoluteString)") }
    }

    /// The GitHub release page with that version's notes.
    func releaseNotesURL(for version: String) -> URL? {
        releasesURL.flatMap { URL(string: "\($0)/tag/v\(version)") }
    }

    func dismissBanner() {
        dismissedVersion = availableVersion
    }

    /// The URL to open for installing the latest release.
    func beginInstall() -> URL? {
        guard let installURL else { return nil }
        isAwaitingInstall = true
        return installURL
    }

    /// The install was cancelled, or the app left the foreground (where the install either
    /// proceeds and ends this process, or was cancelled after all).
    func endInstall() {
        isAwaitingInstall = false
    }

    #if canImport(UIKit)
    /// Goes to the Home Screen, as the Home gesture would, and quits, so that iOS can
    /// replace the app. It's the only way to finish an install started from inside it.
    func closeAppToFinishInstall() {
        let suspend = NSSelectorFromString("suspend")
        guard UIApplication.shared.responds(to: suspend) else { exit(0) }
        _ = UIApplication.shared.perform(suspend)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { exit(0) }
    }
    #endif

    func checkIfDue() async {
        if let lastCheck, Date().timeIntervalSince(lastCheck) < Self.checkInterval { return }
        await check()
    }

    func check() async {
        guard let manifestURL, !isChecking else { return }
        isChecking = true
        defer { isChecking = false }
        lastCheck = Date()

        let request = URLRequest(url: manifestURL, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let latest = Self.latestVersion(inManifest: data, bundleIdentifier: Bundle.main.bundleIdentifier ?? "")
        else {
            lastCheckFailed = true
            return
        }
        lastCheckFailed = false
        availableVersion = Self.isVersion(latest, newerThan: Self.currentVersion) ? latest : nil
    }

    /// The version an over-the-air install manifest offers for this app.
    nonisolated static func latestVersion(inManifest data: Data, bundleIdentifier: String) -> String? {
        guard let manifest = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let items = manifest["items"] as? [[String: Any]],
              let metadata = items.first?["metadata"] as? [String: Any],
              metadata["bundle-identifier"] as? String == bundleIdentifier
        else { return nil }
        return metadata["bundle-version"] as? String
    }

    /// Compares dotted version numbers ("1.10" is newer than "1.9", "1.2.0" equals "1.2").
    /// Anything that isn't one is never newer.
    nonisolated static func isVersion(_ candidate: String, newerThan current: String) -> Bool {
        guard let new = numbers(candidate) else { return false }
        guard let old = numbers(current) else { return true }
        for index in 0..<max(new.count, old.count) {
            let a = index < new.count ? new[index] : 0
            let b = index < old.count ? old[index] : 0
            if a != b { return a > b }
        }
        return false
    }

    private nonisolated static func numbers(_ version: String) -> [Int]? {
        let parts = version.split(separator: ".", omittingEmptySubsequences: false).map { Int($0) }
        guard !parts.isEmpty, parts.allSatisfy({ ($0 ?? -1) >= 0 }) else { return nil }
        return parts.compactMap { $0 }
    }
}
