# Contributing to Resonance

## Environment

Use Xcode 27 or later to open the JSON-based project configuration. Resonance targets macOS 26.0 and uses Swift 6 concurrency checking. [Xcode project format compatibility](https://developer.apple.com/documentation/xcode/updating-your-xcode-project-configuration-file-format)

GitHub Actions builds and tests on macOS 27 using the Apple silicon Xcode 27 runner. [Runner image](https://github.com/actions/runner-images/blob/main/images/macos/xcode-27-arm64-Readme.md)

Run the same checks locally with this command.

```sh
scripts/check
```

The command runs the package suite with `swift test`, builds the macOS app, and executes the **Deterministic** app-hosted plan. Xcode results are under `DerivedData/Logs/Test`. The package suite tests buffer ownership, conversion, the recognition state machine, and real offline ShazamKit matching. The app-hosted suite adds presentation, shortcut settings, and the assembled workflow with real conversion and local catalog recognition. Both use generated audio and do not require audio permission, network service, or an Apple Developer account. There are no snapshot or automation-based UI tests. [Synthetic fixture provenance](docs/shazam-recognition.md#offline-fixture)

## Signing and live tests

1. Copy `Resonance/Configuration/Local.example.xcconfig` to `Local.xcconfig` in the same directory. Set `DEVELOPMENT_TEAM` and `RESONANCE_BUNDLE_IDENTIFIER` using your Apple Developer team and registered App ID.
2. Install an Apple Development signing identity in the keychain that Xcode uses. Enable the [ShazamKit App Service](https://developer.apple.com/help/account/services/shazamkit/) on the registered App ID for default-catalog tests.
3. Run the desired opt-in mode from an interactive macOS desktop. Use one live job at a time. If macOS asks, allow system audio recording for the signed app. For permission troubleshooting, go to **System Settings → Privacy & Security → Screen & System Audio Recording**.

```sh
# Capture a generated recording played by a separate process and recognize it offline.
scripts/check-live system

# Supply a lawful playable audio file with recognizable music at the start.
RESONANCE_LIVE_FIXTURE_PATH=/absolute/path/to/recording.m4a \
RESONANCE_EXPECTED_TITLE='Expected song title' \
RESONANCE_EXPECTED_ARTIST='Expected artist' \
scripts/check-live catalog
```

The live runner forwards these variables using Xcode's `TEST_RUNNER_` mechanism. It generates and removes a temporary playback file for the system test. Captured PCM stays in memory. For manual Chrome testing, launch the signed app outside Xcode, play a known catalog track, and trigger recognition from the menu bar and the shortcut. Record results by output route and permission state in the [validation matrix](docs/validation.md).

## Direct-download builds

Install a valid **Developer ID Application** identity and configure the same registered App ID for distribution. Use `xcrun notarytool store-credentials` to create a named Keychain profile according to Apple's setup. Keep key material, Developer ID credentials, and `Local.xcconfig` outside source control. The script verifies the app on the designated Apple Developer team.

```sh
export RESONANCE_RELEASE_TEAM=YOURTEAMID
export RESONANCE_RELEASE_BUNDLE_ID=your.registered.bundle
scripts/release build

export RESONANCE_NOTARY_PROFILE=your-notary-profile
scripts/release notarize
```

`build` archives and exports a verified Developer ID-signed app to `dist/Resonance.app`. `notarize` builds and exports the app, submits a ZIP, staples the accepted ticket to the app, then creates and verifies `dist/Resonance.zip`. The first distribution build targets Apple silicon. Use a macOS 26+ Apple silicon Mac to validate installation and launch of the finished download before publishing. [Apple notarization workflow](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution)

Publishing a release and choosing a source license are owner decisions. A public repository alone does not provide an open-source license.
