# Resonance

Resonance is a native macOS menu bar app for identifying music playing on the Mac. It requires macOS 26 or later.

## Build and test

Open `Resonance.xcodeproj` with Xcode 26 or newer and select the **Resonance** scheme. The default test plan runs without system audio permission or an Apple Developer account. From the repository root, run `scripts/check` to run package tests, build the app, and run the deterministic Xcode plan.

For account-backed testing, copy `Resonance/Configuration/Local.example.xcconfig` to `Local.xcconfig` in the same directory. Set your development team and registered bundle identifier. Enable the [ShazamKit App Service](https://developer.apple.com/help/account/services/shazamkit/) for that App ID before testing the default Shazam catalog.

The opt-in `Live` test plan uses an app host with the configured bundle identity:

```sh
xcodebuild -project Resonance.xcodeproj -scheme Resonance \
  -testPlan Live -destination 'platform=macOS' -derivedDataPath DerivedData test
```
