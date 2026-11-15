import RecognitionCore
import RecognitionTestSupport
import Testing

@Test func `Fakes carry one attempt through the pipeline`() async throws {
    let attemptID = RecognitionAttemptID()
    let capture = FakeAudioCapture()
    let matcher = FakeRecognition()
    let updates = try await matcher.start(attemptID: attemptID)
    let frames = try await capture.start(attemptID: attemptID)
    let sample = PCMFrame(attemptID: attemptID, position: 0, samples: [0.5])

    await capture.send(sample)
    await capture.stop()
    for try await frame in frames {
        await matcher.submit(frame)
    }

    let result = RecognitionUpdate(attemptID: attemptID, event: .noMatch(isFinal: true))
    await matcher.finishInput()
    await matcher.send(result)
    await matcher.stop()
    var iterator = updates.makeAsyncIterator()
    #expect(await iterator.next() == result)
    #expect(await iterator.next() == nil)
    #expect(await matcher.frames == [sample])
}

@Test func `Manual clock supports elapsed and cancelled deadlines`() async throws {
    let clock = ManualRecognitionClock()
    let sleeper = Task { try await clock.sleep(until: .seconds(5)) }
    await clock.advance(by: .seconds(5))
    try await sleeper.value

    let cancelled = Task { try await clock.sleep(until: .seconds(10)) }
    cancelled.cancel()
    await #expect(throws: CancellationError.self) { try await cancelled.value }
}
