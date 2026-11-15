import Foundation
import RecognitionCore
import ShazamFixtureSupport
import ShazamKit
import Synchronization
import Testing

@testable import ShazamRecognition

@Test(.timeLimit(.minutes(1)))
func `Finishing input supersedes a stalled early query with the longer signature`() async throws {
    let probe = MatchProbe()
    let client = ShazamRecognitionClient(makeSession: { TestSession(probe: probe) })
    let attempt = RecognitionAttemptID()
    let events = try await client.start(attemptID: attempt)
    var requests = probe.requests.stream.makeAsyncIterator()

    try await submit(to: client, attempt: attempt, seconds: 0..<5)
    let early = try #require(await requests.next())
    #expect(early.duration == 5)

    try await submit(to: client, attempt: attempt, seconds: 5..<10)
    await client.finishInput()
    await client.finishInput()
    try #require(probe.requestCount.withLock { $0 } == 2)
    #expect(probe.invalidations.withLock { $0 } == 1)

    let final = try #require(await requests.next())
    #expect(final.duration == 10)
    #expect(final.sessionID != early.sessionID)
    early.complete(.match(RecognizedTrack(id: "stale", title: "Old callback", artist: nil)))
    let track = RecognizedTrack(id: "current", title: "Full clip match", artist: "Test Artist")
    final.complete(.match(track))
    var iterator = events.makeAsyncIterator()
    #expect(await iterator.next() == RecognitionUpdate(attemptID: attempt, event: .match(track)))
    #expect(await iterator.next() == nil)
    #expect(probe.invalidations.withLock { $0 } == 2)
}

@Test(.timeLimit(.minutes(1))) func `Finishing input retains an early query when no audio was added`() async throws {
    let probe = MatchProbe()
    let client = ShazamRecognitionClient(makeSession: { TestSession(probe: probe) })
    let attempt = RecognitionAttemptID()
    var updates = try await client.start(attemptID: attempt).makeAsyncIterator()
    var requests = probe.requests.stream.makeAsyncIterator()
    try await submit(to: client, attempt: attempt, seconds: 0..<5)
    let early = try #require(await requests.next())

    await client.finishInput()
    #expect(probe.requestCount.withLock { $0 } == 1)
    #expect(probe.invalidations.withLock { $0 } == 0)

    early.complete(.noMatch)
    #expect(await updates.next()?.event == .noMatch(isFinal: true))
    #expect(await updates.next() == nil)
    #expect(probe.invalidations.withLock { $0 } == 1)
}

@Test(.timeLimit(.minutes(1))) func `A final session setup failure closes the attempt`() async throws {
    let probe = MatchProbe()
    let createdSession = Mutex(false)
    let failure = RecognitionFailure.recognitionService(diagnostic: "Final session setup failed")
    let client = ShazamRecognitionClient(makeSession: {
        let alreadyCreated = createdSession.withLock { created in
            let alreadyCreated = created
            created = true
            return alreadyCreated
        }
        guard !alreadyCreated else { throw failure }
        return TestSession(probe: probe)
    })
    let attempt = RecognitionAttemptID()
    var updates = try await client.start(attemptID: attempt).makeAsyncIterator()

    try await submit(to: client, attempt: attempt, seconds: 0..<10)
    await client.finishInput()

    #expect(await updates.next()?.event == .failure(failure))
    #expect(await updates.next() == nil)
    #expect(probe.requestCount.withLock { $0 } == 1)
    #expect(probe.invalidations.withLock { $0 } == 1)
}

@Test func `An intermediate no-match keeps input open`() async throws {
    let probe = MatchProbe()
    let client = ShazamRecognitionClient(makeSession: { TestSession(probe: probe) })
    let attempt = RecognitionAttemptID()
    var updates = try await client.start(attemptID: attempt).makeAsyncIterator()
    var requests = probe.requests.stream.makeAsyncIterator()

    try await submit(to: client, attempt: attempt, seconds: 0..<5)
    let early = try #require(await requests.next())
    early.complete(.noMatch)
    #expect(await updates.next()?.event == .noMatch(isFinal: false))

    await client.finishInput()
    #expect(await updates.next()?.event == .noMatch(isFinal: true))
    #expect(await updates.next() == nil)
    #expect(probe.requestCount.withLock { $0 } == 1)
}

@Test func `Stop invalidates a pending callback and the next attempt has an independent session`() async throws {
    let firstProbe = MatchProbe()
    let first = ShazamRecognitionClient(makeSession: { TestSession(probe: firstProbe) })
    let firstID = RecognitionAttemptID()
    var oldUpdates = try await first.start(attemptID: firstID).makeAsyncIterator()
    var oldRequests = firstProbe.requests.stream.makeAsyncIterator()
    try await submit(to: first, attempt: firstID, seconds: 0..<5)
    let pending = try #require(await oldRequests.next())

    await first.stop()
    await first.stop()

    let secondProbe = MatchProbe()
    let second = ShazamRecognitionClient(makeSession: { TestSession(probe: secondProbe) })
    let secondID = RecognitionAttemptID()
    var newUpdates = try await second.start(attemptID: secondID).makeAsyncIterator()
    pending.complete(.match(RecognizedTrack(id: "stale", title: "Old match", artist: nil)))
    await second.finishInput()

    #expect(await oldUpdates.next() == nil)
    #expect(await newUpdates.next() == RecognitionUpdate(attemptID: secondID, event: .noMatch(isFinal: true)))
    #expect(firstProbe.invalidations.withLock { $0 } == 1)
    #expect(secondProbe.requestCount.withLock { $0 } == 0)
}

@Test func `Only ordered finite PCM from this attempt affects the signature`() async throws {
    let probe = MatchProbe()
    let client = ShazamRecognitionClient(makeSession: { TestSession(probe: probe) })
    let attempt = RecognitionAttemptID()
    _ = try await client.start(attemptID: attempt)
    try await client.submit(PCMFrame(attemptID: RecognitionAttemptID(), position: 0, samples: [0.2]))
    try await client.submit(PCMFrame(attemptID: attempt, position: 0, samples: []))

    await #expect(throws: RecognitionFailure.captureInterrupted) {
        try await client.submit(PCMFrame(attemptID: attempt, position: 1, samples: [0.2]))
    }
    try await client.submit(PCMFrame(attemptID: attempt, position: 0, samples: [0.2]))
    await #expect(throws: RecognitionFailure.captureInterrupted) {
        try await client.submit(PCMFrame(attemptID: attempt, position: 1, samples: [Float.nan]))
    }
    await client.stop()
}

@Test func `A shorter catalog maximum caps the final analyzed audio`() async throws {
    let probe = MatchProbe()
    let client = ShazamRecognitionClient(makeSession: { TestSession(probe: probe, maximumDuration: 6) })
    let attempt = RecognitionAttemptID()
    _ = try await client.start(attemptID: attempt)
    var requests = probe.requests.stream.makeAsyncIterator()

    try await submit(to: client, attempt: attempt, seconds: 0..<10)
    let early = try #require(await requests.next())
    #expect(early.duration == 5)
    await client.finishInput()
    try #require(probe.requestCount.withLock { $0 } == 2)
    let final = try #require(await requests.next())
    #expect(final.duration == 6)
    await client.stop()
}

@Test func `Signature boundaries come from the session catalog`() throws {
    let policy = try SignatureQueryPolicy(minimumDuration: 7, maximumDuration: 8, captureDuration: .seconds(10))

    #expect(policy.earlyFrameCount == 7 * Int64(PCMFrame.sampleRate))
    #expect(policy.maximumFrameCount == 8 * Int64(PCMFrame.sampleRate))
    #expect(!policy.accepts(duration: 6.999))
    #expect(policy.accepts(duration: 7))
    #expect(policy.accepts(duration: 8))
    #expect(!policy.accepts(duration: 8.001))
    #expect(throws: RecognitionFailure.self) {
        try SignatureQueryPolicy(minimumDuration: 11, maximumDuration: 20, captureDuration: .seconds(10))
    }
}

private func submit(
    to client: ShazamRecognitionClient,
    attempt: RecognitionAttemptID,
    seconds: Range<Int>
) async throws {
    let rate = Int(PCMFrame.sampleRate)
    for second in seconds {
        let start = second * rate
        let samples = ShazamFixture.samples(in: start..<(start + rate))
        try await client.submit(PCMFrame(attemptID: attempt, position: Int64(start), samples: samples))
    }
}

private final class MatchProbe: Sendable {
    struct Request: Sendable {
        let sessionID: UUID
        let duration: TimeInterval
        let complete: @Sendable (SignatureMatch) -> Void
    }

    let requests = AsyncStream<Request>.makeStream()
    let requestCount = Mutex(0)
    let invalidations = Mutex(0)
}

private final class TestSession: SignatureMatchingSession {
    let id = UUID()
    let probe: MatchProbe
    let minimumDuration: TimeInterval
    let maximumDuration: TimeInterval

    init(probe: MatchProbe, minimumDuration: TimeInterval = 1, maximumDuration: TimeInterval = 12) {
        self.probe = probe
        self.minimumDuration = minimumDuration
        self.maximumDuration = maximumDuration
    }

    func match(_ signature: SHSignature, completion: @escaping @Sendable (SignatureMatch) -> Void) {
        probe.requestCount.withLock { $0 += 1 }
        probe.requests.continuation.yield(MatchProbe.Request(
            sessionID: id, duration: signature.duration, complete: completion
        ))
    }

    func invalidate() {
        probe.invalidations.withLock { $0 += 1 }
    }
}
