# Resonance 0.1.0

Requires macOS 26 or later. The initial distribution script builds for Apple silicon.

- Recognize music playing in other apps from the menu bar or with an optional global shortcut.
- Cancel during recognition, and open the result in Apple Music when the catalog provides a link.
- System audio is captured on demand. macOS asks for system audio access on first use. Recognition against the public Shazam catalog requires network access.

An output route change ends the current attempt. Mixed playback can interfere with recognition. Protected sources and alternate output routes need separate validation. See the [validation record](validation.md) for coverage and remaining live checks.
