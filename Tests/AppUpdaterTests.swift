import XCTest

final class AppUpdaterTests: XCTestCase {
    func testVersionOrdering() {
        XCTAssertTrue(AppUpdater.isVersion("1.2.1", newerThan: "1.2.0"))
        XCTAssertTrue(AppUpdater.isVersion("1.10", newerThan: "1.9"))
        XCTAssertTrue(AppUpdater.isVersion("2.0", newerThan: "1.99.9"))
        XCTAssertTrue(AppUpdater.isVersion("1.2.1", newerThan: "1.2"))
        XCTAssertFalse(AppUpdater.isVersion("1.2.0", newerThan: "1.2"))
        XCTAssertFalse(AppUpdater.isVersion("1.2", newerThan: "1.2.0"))
        XCTAssertFalse(AppUpdater.isVersion("1.1.9", newerThan: "1.2"))
    }

    func testMalformedVersions() {
        XCTAssertFalse(AppUpdater.isVersion("", newerThan: "1.0"))
        XCTAssertFalse(AppUpdater.isVersion("1.x", newerThan: "1.0"))
        XCTAssertFalse(AppUpdater.isVersion("1..2", newerThan: "1.0"))
        XCTAssertFalse(AppUpdater.isVersion("-2", newerThan: "1.0"))
        // An unreadable installed version is replaced by any real release.
        XCTAssertTrue(AppUpdater.isVersion("1.2.0", newerThan: "?"))
    }

    func testManifestVersion() throws {
        let manifest = try manifestData(bundleIdentifier: "localdesktop.client", version: "1.2.0")
        XCTAssertEqual(AppUpdater.latestVersion(inManifest: manifest, bundleIdentifier: "localdesktop.client"), "1.2.0")
        // A manifest for some other app is ignored.
        XCTAssertNil(AppUpdater.latestVersion(inManifest: manifest, bundleIdentifier: "other.app"))
        XCTAssertNil(AppUpdater.latestVersion(inManifest: Data("<html></html>".utf8), bundleIdentifier: "localdesktop.client"))
    }

    private func manifestData(bundleIdentifier: String, version: String) throws -> Data {
        let manifest: [String: Any] = [
            "items": [[
                "assets": [["kind": "software-package", "url": "https://example.com/LocalDesktop-\(version).ipa"]],
                "metadata": [
                    "bundle-identifier": bundleIdentifier,
                    "bundle-version": version,
                    "kind": "software",
                    "title": "LocalDesktop",
                ],
            ]],
        ]
        return try PropertyListSerialization.data(fromPropertyList: manifest, format: .xml, options: 0)
    }
}
