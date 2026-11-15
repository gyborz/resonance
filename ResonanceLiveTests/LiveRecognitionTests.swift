import AVFoundation
import Foundation
import RecognitionCore
import Security
import ShazamFixtureSupport
import ShazamRecognition
import SystemAudioCapture
import Testing

@Suite(.serialized, .timeLimit(.minutes(2)))
struct LiveRecognitionTests {
    @Test("Captures and recognizes the generated catalog fixture")
    func localCatalogFromSystemAudio() async throws {
        try requireSignedHost()

        let directory = FileManager.default.temporaryDirectory
            .appending(path: "Resonance-Live-\(UUID())", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }

        let fixture = directory.appending(path: "ShazamFixture.wav")
        try ShazamFixture.writePlaybackFile(to: fixture)
        let catalog = try ShazamFixture.catalogData()
        let track = try await recognizePlaying(fixture) { policy in
            ShazamRecognitionClient(customCatalogData: catalog, policy: policy)
        }

        #expect(track.title == ShazamFixture.title)
        #expect(track.artist == ShazamFixture.artist)
        #expect(track.appleMusicURL == ShazamFixture.musicURL)
    }

    @Test("Recognizes the supplied fixture with the default Shazam catalog")
    func defaultCatalogFromSystemAudio() async throws {
        try requireSignedHost()

        let environment = ProcessInfo.processInfo.environment
        let path = try requiredValue("RESONANCE_LIVE_FIXTURE_PATH", in: environment)
        let expectedTitle = try requiredValue("RESONANCE_EXPECTED_TITLE", in: environment)
        let expectedArtist = try requiredValue("RESONANCE_EXPECTED_ARTIST", in: environment)
        let fixture = URL(filePath: path)
        guard let file = try? AVAudioFile(forReading: fixture), file.length > 0 else {
            throw LiveTestError("Set RESONANCE_LIVE_FIXTURE_PATH to a readable audio file containing a known recording you have permission to play.")
        }

        let track = try await recognizePlaying(fixture) { policy in
            ShazamRecognitionClient(policy: policy)
        }

        #expect(track.title == expectedTitle)
        #expect(track.artist == expectedArtist)
    }

    private func requiredValue(_ name: String, in environment: [String: String]) throws -> String {
        guard let value = environment[name], !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw LiveTestError("Set \(name) in the live test runner environment.")
        }
        return value
    }
}

private func requireSignedHost() throws {
    let bundle = Bundle.main
    guard bundle.bundleURL.pathExtension == "app",
          let identifier = bundle.bundleIdentifier,
          identifier != "local.resonance.development",
          let audioPurpose = bundle.object(forInfoDictionaryKey: "NSAudioCaptureUsageDescription") as? String,
          !audioPurpose.isEmpty else {
        throw LiveTestError("Run the Live test plan in the Resonance app host. Set the registered App ID in Resonance/Configuration/Local.xcconfig.")
    }

    let noFlags = SecCSFlags(rawValue: 0)
    var code: SecStaticCode?
    let codeStatus = SecStaticCodeCreateWithPath(bundle.bundleURL as CFURL, noFlags, &code)
    guard codeStatus == errSecSuccess, let code else {
        throw LiveTestError("The test runner could not locate the Resonance app signature. Build the app host with a development signing identity.")
    }

    var signingInformation: CFDictionary?
    let signingStatus = SecCodeCopySigningInformation(
        code, SecCSFlags(rawValue: kSecCSSigningInformation), &signingInformation
    )
    guard signingStatus == errSecSuccess,
          let information = signingInformation as? [String: Any],
          let team = information[kSecCodeInfoTeamIdentifier as String] as? String,
          !team.isEmpty,
          information[kSecCodeInfoIdentifier as String] as? String == identifier,
          SecStaticCodeCheckValidity(code, noFlags, nil) == errSecSuccess else {
        throw LiveTestError("Sign the Resonance app host with an Apple development team and the configured App ID before running the Live plan.")
    }
}

private func recognizePlaying(
    _ fixture: URL,
    makeRecognizer: @escaping @Sendable (RecognitionPolicy) -> any RecognitionClient
) async throws -> RecognizedTrack {
    let policy = RecognitionPolicy()
    let coordinator = RecognitionCoordinator(
        policy: policy,
        makeCapture: { SystemAudioCaptureClient(policy: policy, diagnosticsEnabled: true) },
        makeRecognizer: { makeRecognizer(policy) }
    )
    let player = FixturePlayer()
    let updates = await coordinator.updates()
    await coordinator.recognize()

    let result: Result<RecognizedTrack, any Error>
    do {
        let track = try await withThrowingTaskGroup(of: RecognizedTrack.self) { group in
            group.addTask {
                for await update in updates {
                    try Task.checkCancellation()
                    switch update.state {
                    case .listening:
                        // HAL startup and any system permission prompt have resolved.
                        try await player.play(fixture)
                    case .matched(let track):
                        try await player.checkPlayback()
                        return track
                    case .failed(let failure):
                        try await player.checkForFailure()
                        throw LiveTestError(description(for: failure))
                    case .noMatch:
                        try await player.checkPlayback()
                        throw LiveTestError("No catalog match. Use a quiet playback mix and check that the fixture is audible on the current output route.")
                    case .cancelled:
                        throw LiveTestError("The live recognition attempt was cancelled.")
                    case .idle, .starting, .searching:
                        break
                    }
                }
                try Task.checkCancellation()
                throw LiveTestError("The recognition state stream closed before a result.")
            }
            group.addTask {
                try await Task.sleep(for: .seconds(60))
                if await coordinator.snapshot.state == .starting {
                    throw LiveTestError("System capture did not start within 60 seconds. Resolve the system audio recording prompt and rerun.")
                }
                throw LiveTestError("The live recognition attempt did not finish within 60 seconds.")
            }
            defer { group.cancelAll() }
            return try #require(try await group.next())
        }
        result = .success(track)
    } catch {
        result = .failure(error)
    }

    await player.stop()
    await coordinator.shutdown()
    return try result.get()
}

private func description(for failure: RecognitionFailure) -> String {
    switch failure {
    case .audioPermissionDenied:
        return "Allow system audio recording for Resonance in System Settings > Privacy & Security, then rerun."
    case .noAudio, .silence:
        return "No audible fixture samples reached the tap (\(failure)). Check the output route and system audio recording permission."
    case .recognitionService, .recognitionTimedOut:
        return "ShazamKit returned \(failure). For the default catalog, verify network access and that the host's App ID has ShazamKit enabled."
    case .captureInterrupted, .captureUnavailable:
        return "System capture returned \(failure). Check that the Mac has an active, stable audio output route."
    }
}

/// Only this test actor accesses its afplay child. Every test outcome drains it.
private actor FixturePlayer {
    private var child: Process?

    func play(_ fixture: URL) throws {
        try Task.checkCancellation()
        guard child == nil else { return }
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/afplay")
        process.arguments = [fixture.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            throw LiveTestError("Could not launch the separate afplay fixture process.")
        }
        child = process
    }

    func checkPlayback() throws {
        guard child != nil else {
            throw LiveTestError("Recognition ended before the separate fixture process started.")
        }
        try checkForFailure()
    }

    func checkForFailure() throws {
        if let child, !child.isRunning, child.terminationStatus != 0 {
            throw LiveTestError("afplay exited with status \(child.terminationStatus). Check that the fixture is playable on this Mac.")
        }
    }

    func stop() {
        guard let child else { return }
        if child.isRunning { child.terminate() }
        child.waitUntilExit()
        self.child = nil
    }
}

private struct LiveTestError: LocalizedError, CustomStringConvertible {
    let description: String
    var errorDescription: String? { description }

    init(_ description: String) { self.description = description }
}
