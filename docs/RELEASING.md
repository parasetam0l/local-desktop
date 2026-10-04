# Releasing LocalDesktop

Releases are built by the **Release** GitHub Actions workflow
(`.github/workflows/release.yml`). It runs only when started by hand, runs
the unit tests, and builds both apps from the same commit with the same
version and build number. It creates a **draft** GitHub release with:

- `LocalDesktop-<version>.dmg`: the Mac app (macOS 14+, Apple silicon and
  Intel), signed with a Developer ID certificate and notarized by Apple.
- `LocalDesktop-<version>.ipa`: the iPhone and iPad app (iOS 17+), an Ad Hoc
  build for the devices registered with the team (see
  [The iPhone and iPad app](#the-iphone-and-ipad-app)).

Publishing the release starts the **Appcast** workflow
(`.github/workflows/appcast.yml`), which signs the DMG with the update key and
attaches `appcast.xml`, the feed installed Mac apps check for updates. After
it, the **Install page** workflow (`.github/workflows/install-page.yml`)
publishes the IPA on GitHub Pages with the page iPhones and iPads install it
from, and the `manifest.plist` the iPhone app checks for updates.

The repository is public, so the runner minutes are free.

## One-time setup

You need the paid Apple Developer Program membership of team `P7V7795SS9`.
The certificate and notarization password are the same ones SemiVPN uses, so
if SemiVPN releases work, you already have them.

### 1. Developer ID certificate

The Mac app is signed with the **Developer ID Application** certificate that
is valid until 17 September 2031; `project.yml` pins it by its SHA-1
(`CODE_SIGN_IDENTITY`), and the Release workflow checks that the certificate
in the secret is that one.

If you no longer have the exported `DeveloperID.p12` from SemiVPN's setup:
Keychain Access → My Certificates → Control-click **Developer ID
Application** (the one that expires in 2031) → **Export** → save it as
`DeveloperID.p12` with a strong password.

### 2. App-specific password for notarization

Reuse SemiVPN's, or create one at [account.apple.com](https://account.apple.com)
→ Sign-In and Security → App-Specific Passwords → **+** (label it e.g.
"Local Desktop notarization").

### 3. Update signing key (Sparkle)

Installed copies of LocalDesktop check `appcast.xml` on the latest
published release once a day and install an update only if its EdDSA
signature matches the public key built into the app (`SUPublicEDKey` in
`project.yml`).

The key pair already exists: the private key is in your login keychain under
the account `localdesktop`, and its public key is in `project.yml`. **Keep
the private key**: if it is lost, installed copies can't update anymore
(they would need a manual reinstall with a new key). To back it up, export
it as below and store the file somewhere safe and private.

Sparkle's tools come with the Sparkle package; build once so they are
downloaded (`./build.sh --host`), then export the key for the workflow:

```sh
build/SourcePackages/artifacts/sparkle/Sparkle/bin/generate_keys --account localdesktop -x sparkle-private.key
```

### 4. App Store Connect API key (iPhone app)

The workflow signs the iPhone app the way Xcode does: with the team's
cloud-managed **Apple Distribution** certificate (Apple keeps its private
key) and an Ad Hoc provisioning profile it creates or renews on every
release. An App Store Connect API key lets it do that without your Apple ID.
Nothing is submitted to the App Store.

[App Store Connect](https://appstoreconnect.apple.com) → Users and Access →
Integrations → App Store Connect API → **Team Keys** → **+**: name it e.g.
"LocalDesktop CI" with **Admin** access (needed for the cloud-managed
certificate). Download `AuthKey_<Key ID>.p8`; it can be downloaded only
once. Note the **Key ID** and the **Issuer ID** shown on that page.

If the key leaks, revoke it on the same page and add a new one.

### 5. Repository secrets

With the [GitHub CLI](https://cli.github.com), in the repository folder.
`gh secret set NAME` without a value asks for it, so it stays out of your
shell history. `NOTARY_APPLE_ID` is your Apple ID e-mail and
`NOTARY_PASSWORD` the app-specific password from step 2:

```sh
base64 -i DeveloperID.p12 | gh secret set DEVELOPER_ID_P12_BASE64
gh secret set DEVELOPER_ID_P12_PASSWORD
gh secret set NOTARY_APPLE_ID
gh secret set NOTARY_PASSWORD
gh secret set SPARKLE_PRIVATE_KEY < sparkle-private.key
gh secret set APP_STORE_CONNECT_KEY < AuthKey_XXXXXXXXXX.p8
gh secret set APP_STORE_CONNECT_KEY_ID
gh secret set APP_STORE_CONNECT_ISSUER_ID
```

Then delete the exported files; the certificate and the Sparkle key stay in
your keychain (keep a private copy of the `.p8` if you like, or make a new
key when you need one):

```sh
rm DeveloperID.p12 sparkle-private.key AuthKey_XXXXXXXXXX.p8
```

These are repository secrets: only this repository's workflows can read
them, and not when started from forks.

### 6. GitHub Pages (iPhone install page)

iOS installs an Ad Hoc app over the air only from an `itms-services://` link
on a web page (GitHub strips such links from release notes), so the Install
page workflow publishes one on GitHub Pages. Turn Pages on once: GitHub →
Settings → Pages → Build and deployment → Source: **GitHub Actions**. Or:

```sh
gh api -X POST repos/parasetam0l/local-desktop/pages -f build_type=workflow
```

The page is https://parasetam0l.github.io/local-desktop/. The iPhone app
checks its `manifest.plist` for updates; that address is
`LDUpdateManifestURL` in `project.yml`.

## Making a release

1. GitHub → **Actions** → **Release** → **Run workflow**, enter the version
   (e.g. `1.2.0`) and run it. It takes about 10–30 minutes, most of it
   waiting for Apple's notary service. The run's summary says how many
   devices the iPhone app installs on and until when it runs.
2. GitHub → **Releases**: edit the draft's notes and **Publish** it.
   Publishing creates the `v<version>` tag. The notes have install and update
   steps and the subjects of the commits since the previous release: add a
   short summary of what changed for users and remove internal entries
   (build, docs).
3. Publishing starts the **Appcast** workflow (about 2 minutes): it signs the
   DMG with the update key, checks the signature against the key in the app,
   and attaches `appcast.xml` with the release notes as published. From then
   on installed copies offer the update. To redo it (after editing the notes,
   for example), run Actions → **Appcast** → Run workflow with the tag.
4. When the Appcast workflow succeeds, the **Install page** workflow (about
   a minute) puts the release's IPA on the install page. From then on the
   iPhone app offers the update. To redo it, run Actions → **Install page**
   → Run workflow; it always publishes the latest release.

If a step fails, its log says why; the xcodebuild log is attached to the run
as an artifact, and a notarization failure prints Apple's report.

## What users see

On the Mac:

- They open the DMG and drag LocalDesktop to Applications. Gatekeeper
  accepts it without warnings because it is notarized. On first launch the
  Setup Assistant asks for Screen Recording, Accessibility, and a PIN.
- The app checks for updates once a day and shows the new version with its
  release notes; it installs only when they choose **Install Update**, then
  relaunches. The gear menu in the menu bar panel has **Check for Updates…**
  and the switch for automatic checks.
- Every release is signed with the same certificate, so macOS keeps the
  Screen Recording and Accessibility permissions across updates.
- Copies built before the updater existed (and builds from `./build.sh`
  with a different version) update once by hand.

On an iPhone or iPad:

- They open https://parasetam0l.github.io/local-desktop/ in Safari, tap
  **Install on this device**, and confirm. Installing over an older version
  (or a development build from `./build.sh`) keeps the paired Macs and
  settings, since the bundle identifier and team are the same.
- From 1.2 on, the app checks the install page when it opens (at most every
  six hours) and shows a banner with **Install** when a newer version is
  out. Settings → Updates shows the version and checks by hand.

## The iPhone and iPad app

There's no App Store version. Releases are **Ad Hoc** builds: they install
only on the devices registered with the team when the release was built.

- **Adding a device:** register it at
  [developer.apple.com](https://developer.apple.com/account/resources/devices/list)
  → Devices → **+** with its UDID (or connect it once and run
  `./build.sh --client --install`), then make a release; its profile
  includes every enabled device. Disabled devices are left out; Apple
  removes them, freeing their slots, when the membership renews.
- **The device list is public:** the profile inside the IPA lists the UDIDs
  of the devices it installs on, and anyone can download the IPA. Keep only
  your own devices enabled.
- **Expiry:** the Ad Hoc profile is valid for a year from when Xcode
  created it, and Xcode reuses it for every release until then, so all
  installed releases stop opening on the same date (the run's summary has
  it; the current profile expires on 4 October 2027). From 60 days before,
  the Release workflow warns. Then delete the profile at
  [developer.apple.com](https://developer.apple.com/account/resources/profiles/list)
  → Profiles → "iOS Team Ad Hoc Provisioning Profile: localdesktop.client"
  and make a release: Xcode creates a new profile for another year, and
  installing that release keeps the app opening.
- **Development builds** (`./build.sh --client --install`, or Xcode) still
  work as before. They're version 1.0, so they offer the latest release,
  which replaces them when installed.

## Notes

- Release builds get the Unix time as their build number, so every release
  is newer than the last for Sparkle. Both apps of a release get the same
  build number.
- The iPhone app is archived without signing and signed when exported, with
  `Packaging/ios/ExportOptions.plist`. To try it locally (Xcode signs with
  your account instead of the API key):
  `xcodebuild archive -scheme LocalDesktopClient -destination generic/platform=iOS -archivePath /tmp/c.xcarchive CODE_SIGNING_ALLOWED=NO`,
  then `xcodebuild -exportArchive -archivePath /tmp/c.xcarchive -exportPath /tmp/c -exportOptionsPlist Packaging/ios/ExportOptions.plist -allowProvisioningUpdates`.
- The install page's layout is `Packaging/ios/index.html`;
  `Scripts/install-page.py` fills it in with the manifest from a release's
  IPA.
- The DMG window's layout is in `Packaging/dmg` (dmgbuild settings and the
  background). After changing it, redraw the background with
  `swift Scripts/dmg-background.swift` and try it with
  `Scripts/make-dmg.sh path/to/LocalDesktop.app test.dmg`.
- The Mac app icon is built from `Packaging/icon/artwork-1024.png`: run
  `swift Scripts/mac-app-icon.swift` after changing the artwork. It cuts the
  rounded tile out onto Apple's icon grid with transparent corners.
- The Developer ID certificate is valid until 2031. When it is renewed,
  update `CODE_SIGN_IDENTITY` in `project.yml` and the
  `DEVELOPER_ID_P12_*` secrets.
