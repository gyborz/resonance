# Resonance

Resonance is a macOS menu bar app that identifies music playing in other apps. It uses the system audio mix, so you can keep listening in Chrome, Safari, or a local player while it works.

## Use Resonance

1. Play a song in another app.
2. Open Resonance in the menu bar and choose **Recognize Song**. On first use, continue through the explanation and allow system audio recording when macOS prompts you.
3. After a match, the popover shows the title and artist. Choose **Open in Apple Music** if Shazam returns a link.

In **Settings**, you can assign a global shortcut to recognize music while another app is active. Press **Cancel** to end an active request. Closing the popover leaves the request running.

## Build and test

Build with Xcode 26 or later on macOS 26 or later. Open `Resonance.xcodeproj`, select **Resonance**, and choose **Run**. The default development configuration builds with a local bundle identifier. Configure a registered App ID and signing identity to use the default Shazam catalog.

Run `scripts/check` for package tests, the Xcode app build, and app-hosted deterministic tests. See the [contributor guide](CONTRIBUTING.md) for signing setup and optional live tests, and the [validation record](docs/validation.md) for results.

## Privacy

Resonance captures system audio when you start a recognition attempt. It discards raw audio after the attempt and keeps the last match only for the current launch. The public catalog uses Apple's Shazam service, which receives an audio signature for matching. Resonance has no custom backend and stores no recordings. Artwork links may be loaded when the result is displayed. [ShazamKit](https://developer.apple.com/shazamkit/)
