# ShazamKit matching

Each recognition attempt starts with a new `SHSession` and `SHSignatureGenerator`. The client actor submits ordered mono Float32 PCM at 48 kHz and retains up to the smaller of the capture budget and the catalog's maximum query duration in the generator. The catalog supplies both signature duration limits. The client checks the actual generated duration, since it can be shorter than the capture. [SHSignature](https://developer.apple.com/documentation/shazamkit/shsignature)

The client sends at most two explicit signatures. It tries once after half the capture window, adjusted to the catalog bounds. An early match ends the attempt immediately through the coordinator. When input ends with additional audio and a valid longer signature, the client submits it immediately. If the early request is still pending, the client starts the final query in a fresh session and discards later callbacks from the early request. With no longer signature available, an outstanding early request can still produce the result. The coordinator enforces the result deadline. Ending the attempt invalidates delivery and releases the client session and generator. A submitted request may continue within ShazamKit. [SHSession](https://developer.apple.com/documentation/shazamkit/shsession)

The client uses ShazamKit's match order to select the first item with a title or artist. Items with artwork or an Apple Music link provide a fallback, followed by items with only a stable identifier. [SHMatch](https://developer.apple.com/documentation/shazamkit/shmatch)

In a local macOS 27.2 probe, `matchStreamingBuffer(_:at:)` gave recurring matches for ten seconds of a known custom-catalog recording. An unrelated recording produced no callback before or after input stopped. Explicit queries against the same catalog produced a match and a no-match respectively. Explicit submission lets the app define a finite end-of-input policy.

## Offline fixture

`ShazamFixtureSupport` generates a 16-second reference recording in memory from seeded pitches, envelopes, and amplitudes. The matching tests submit an excerpt starting two seconds into the reference. The unrelated excerpt uses a different seed and separate pitch ranges. The waveforms and metadata are built entirely from original test data. The Apple Music URL in the fixture is placeholder metadata used only to verify round-trip mapping.

Run `swift test --package-path Packages/ResonanceKit` to exercise the real local catalog alongside the client tests. The custom catalog runs on-device with generated audio. For default-catalog testing, sign the app with a registered bundle identifier whose App ID has the ShazamKit App Service enabled. [Enable ShazamKit for an App ID](https://developer.apple.com/help/account/services/shazamkit/)
