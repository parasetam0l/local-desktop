# Releasing LocalDesktop (Mac)

Releases are built by the **Release** GitHub Actions workflow
(`.github/workflows/release.yml`). It runs only when started by hand, runs
the unit tests, signs LocalDesktop with a Developer ID certificate, has
Apple notarize it, and creates a **draft** GitHub release with
`LocalDesktop-<version>.dmg` (macOS 14+, Apple silicon and Intel).
Publishing the release starts the **Appcast** workflow
(`.github/workflows/appcast.yml`), which signs the DMG with the update key and
attaches `appcast.xml`, the feed installed copies check for updates.

The repository is public, so the macOS runner minutes are free.

The iOS app is not released by these workflows (see [The iOS app](#the-ios-app)).

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

### 4. Repository secrets

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
```

Then delete the exported files; the certificate and the key stay in your
keychain:

```sh
rm DeveloperID.p12 sparkle-private.key
```

These are repository secrets: only this repository's workflows can read
them, and not when started from forks.

## Making a release

1. GitHub → **Actions** → **Release** → **Run workflow**, enter the version
   (e.g. `1.1.0`) and run it. It takes about 10–30 minutes, most of it
   waiting for Apple's notary service.
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

If a step fails, its log says why; the xcodebuild log is attached to the run
as an artifact, and a notarization failure prints Apple's report.

## What users see

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

## The iOS app

iPhones and iPads only install apps from the App Store, TestFlight, or a
development build, so the client can't update itself like the Mac app.
Install it with `./build.sh --client --install` (a development build that
runs until its provisioning profile expires, at most a year). Automatic
updates for it would mean distributing it through TestFlight.

## Notes

- Release builds get the Unix time as their build number, so every release
  is newer than the last for Sparkle.
- The DMG window's layout is in `Packaging/dmg` (dmgbuild settings and the
  background). After changing it, redraw the background with
  `swift Scripts/dmg-background.swift` and try it with
  `Scripts/make-dmg.sh path/to/LocalDesktop.app test.dmg`.
- The Developer ID certificate is valid until 2031. When it is renewed,
  update `CODE_SIGN_IDENTITY` in `project.yml` and the
  `DEVELOPER_ID_P12_*` secrets.
