# Validation record

Local checks ran on November 15, 2026, on Apple silicon with macOS 27.2 (26B123) and Xcode 27.2 (27B52). The deployment target is macOS 26.0.

| Check | Result |
| --- | --- |
| Swift package tests | Passed. Covers capture ownership and rollback with simulated HAL, six input formats with AVAudioConverter, workflow deadlines and cancellation, and real offline ShazamKit match and no-match. |
| App-hosted deterministic tests | Passed. Includes a generated stereo 44.1 kHz fixture through the real converter, real local Shazam catalog, workflow, and presentation. Also covers shortcut settings, errors, deadlines, cancellation, retry, and shutdown. |
| Release archive | Built for arm64 and passed strict local code-signature verification. The code signature has Hardened Runtime enabled and uses ad-hoc signing. |
| Launch outside Xcode | The archived app launched as a standalone process. The GUI inspection timed out before the menu bar could be checked. |
| Live test plan | Both hardware cases compile and enumerate. The runner refused to start without the local signed-host configuration. |
| Developer ID archive, notarization, stapling, and ZIP installation | Pending a configured Apple Developer team, Developer ID Application identity, and Notary Service credentials. |

## Manual and live matrix

These cases are pending on a signed interactive Mac. See the [contributor guide](../CONTRIBUTING.md) for signing setup and live test commands.

| Case | Evidence to record | Status |
| --- | --- | --- |
| Chrome/YouTube with a known catalog recording | Correct title and artist, Apple Music action when supplied, and uninterrupted Chrome playback. Repeat with the global shortcut while Chrome is frontmost. | Unrun |
| Safari and a local player | Correct recognition independently of Chrome. Run the generated fixture through a separate playback process and the offline catalog. | Unrun |
| Speakers, wired output, and Bluetooth | Output route, capture format, and matching result. | Unrun |
| Route change during capture | Retry guidance appears and capture resources are released. | Unrun |
| Permission prompt, denial, and revocation | Measure whether HAL startup holds while the prompt is open. Verify recovery guidance and retry after granting access. | Unrun |
| Silence, missing buffers, and overlapping audio | Observe bounded listening, distinguish detectable outcomes, verify results against a known track. | Unrun |
| Network unavailable or service error | Bounded response and actionable retry guidance. | Unrun |
| Popover dismissal, quit, and sleep | Dismissal allows a match, quit and sleep stop capture, wake requires a fresh trigger. | Unrun |
| Repeated attempts and rapid cancellation | No accumulating taps, aggregate devices, sessions, or processing tasks. | Unrun |

No live user audio was recorded to disk or included in the test artifacts. The fixture used in automated tests is [generated from original test data](shazam-recognition.md#offline-fixture).
