import RecognitionCore
import ShazamFixtureSupport
import ShazamRecognition
import Testing

@Test func `A five-second excerpt matches the real custom catalog during capture`() async throws {
    let attempt = RecognitionAttemptID()
    let client = ShazamRecognitionClient(customCatalogData: try ShazamFixture.catalogData())
    let updates = try await client.start(attemptID: attempt)

    try await feedExcerpt(to: client, attempt: attempt, seconds: 5)
    let result = try await terminalUpdate(from: updates)
    await client.stop()

    let track = try #require(match(in: result.event))
    #expect(result.attemptID == attempt)
    #expect(track.title == ShazamFixture.title)
    #expect(track.artist == ShazamFixture.artist)
    #expect(track.appleMusicURL == ShazamFixture.musicURL)
    #expect(track.artworkURL == nil)
}

@Test func `Ending a short excerpt submits its final signature`() async throws {
    let attempt = RecognitionAttemptID()
    let client = ShazamRecognitionClient(customCatalogData: try ShazamFixture.catalogData())
    let updates = try await client.start(attemptID: attempt)

    try await feedExcerpt(to: client, attempt: attempt, seconds: 3)
    await client.finishInput()
    let result = try await terminalUpdate(from: updates)
    await client.stop()

    let track = try #require(match(in: result.event))
    #expect(track.title == ShazamFixture.title)
}

@Test func `An unrelated synthesized track receives a real catalog no-match`() async throws {
    let attempt = RecognitionAttemptID()
    let client = ShazamRecognitionClient(customCatalogData: try ShazamFixture.catalogData())
    let updates = try await client.start(attemptID: attempt)

    try await feedExcerpt(to: client, attempt: attempt, seconds: 10, variant: .unrelated)
    await client.finishInput()
    let result = try await terminalUpdate(from: updates)
    await client.stop()

    #expect(result.attemptID == attempt)
    #expect(result.event == .noMatch(isFinal: true))
}

private func match(in event: RecognitionEvent) -> RecognizedTrack? {
    guard case let .match(track) = event else { return nil }
    return track
}

private func feedExcerpt(
    to client: ShazamRecognitionClient,
    attempt: RecognitionAttemptID,
    seconds: Int,
    variant: ShazamFixture.Variant = .reference
) async throws {
    let rate = Int(PCMFrame.sampleRate)
    let excerptStart = 2 * rate
    let bufferSize = rate / 10
    for position in stride(from: 0, to: seconds * rate, by: bufferSize) {
        let start = excerptStart + position
        let samples = ShazamFixture.samples(in: start..<(start + bufferSize), variant: variant)
        try await client.submit(PCMFrame(attemptID: attempt, position: Int64(position), samples: samples))
    }
}

private func terminalUpdate(from updates: AsyncStream<RecognitionUpdate>) async throws -> RecognitionUpdate {
    try await withThrowingTaskGroup(of: RecognitionUpdate.self) { group in
        group.addTask {
            for await update in updates where update.event != .noMatch(isFinal: false) {
                return update
            }
            throw TestError.streamEnded
        }
        group.addTask {
            try await Task.sleep(for: .seconds(5))
            throw TestError.timedOut
        }
        defer { group.cancelAll() }
        return try #require(try await group.next())
    }
}

private enum TestError: Error {
    case timedOut
    case streamEnded
}
