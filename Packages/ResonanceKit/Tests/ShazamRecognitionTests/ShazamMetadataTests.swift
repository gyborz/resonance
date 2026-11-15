import Foundation
import RecognitionCore
import ShazamKit
import Testing

@testable import ShazamRecognition

@Test func `Metadata keeps the first usable item and trims display fields`() throws {
    let empty = SHMediaItem(properties: [.title: " \n", .artist: ""])
    let musicURL = try #require(URL(string: "https://music.apple.com/us/song/fixture"))
    let artworkURL = try #require(URL(string: "https://example.test/artwork.jpg"))
    let usable = SHMediaItem(properties: [
        .shazamID: "123", .title: " Title ", .artist: "Artist\n",
        .appleMusicURL: musicURL, .artworkURL: artworkURL,
    ])
    let recognizedAt = Date(timeIntervalSince1970: 42)

    let track = try #require(ShazamMetadata.firstTrack(in: [empty, usable], recognizedAt: recognizedAt))
    #expect(track == RecognizedTrack(
        id: "shazam:123", title: "Title", artist: "Artist",
        appleMusicURL: musicURL, artworkURL: artworkURL, recognizedAt: recognizedAt
    ))
}

@Test func `Empty and malformed metadata preserves meaningful partial results`() throws {
    #expect(ShazamMetadata.firstTrack(in: []) == nil)
    #expect(ShazamMetadata.firstTrack(in: [SHMediaItem(properties: [:])]) == nil)

    let partial = SHMediaItem(properties: [
        .artist: "\tArtist\n", .title: 123, .appleMusicURL: "not a URL",
    ])
    let item = try #require(ShazamMetadata.firstTrack(in: [partial]))
    #expect(item.title == nil)
    #expect(item.artist == "Artist")
    #expect(item.appleMusicURL == nil)
    #expect(item.artworkURL == nil)
}

@Test func `Named matches take precedence over link-only and ID-only items`() throws {
    let idOnly = SHMediaItem(properties: [.shazamID: "sparse", .title: " \n"])
    let musicURL = try #require(URL(string: "https://music.apple.com/us/song/fixture"))
    let linkOnly = SHMediaItem(properties: [.appleMusicURL: musicURL])
    let named = SHMediaItem(properties: [.shazamID: "named", .title: "Song title", .artist: "Song artist"])
    let later = SHMediaItem(properties: [.title: "Later result"])

    let track = try #require(ShazamMetadata.firstTrack(in: [idOnly, linkOnly, named, later]))
    #expect(track.id == "shazam:named")
    #expect(track.title == "Song title")
    #expect(track.artist == "Song artist")
    #expect(ShazamMetadata.firstTrack(in: [idOnly, linkOnly])?.appleMusicURL == musicURL)
    #expect(ShazamMetadata.firstTrack(in: [idOnly])?.id == "shazam:sparse")
}

@Test func `No-match and invalid fingerprint responses remain distinct from a service failure`() {
    let signatureInvalid = NSError(domain: SHError.errorDomain, code: SHError.Code.signatureInvalid.rawValue)
    #expect(ShazamMetadata.unmatchedResult(error: nil) == .noMatch)
    #expect(ShazamMetadata.unmatchedResult(error: signatureInvalid) == .noMatch)
    let upstream = NSError(domain: SHError.errorDomain, code: SHError.Code.matchAttemptFailed.rawValue)
    #expect(ShazamMetadata.unmatchedResult(error: upstream) == .failure(
        .recognitionService(diagnostic: "\(SHError.errorDomain) (\(upstream.code))")
    ))
}

@Test(arguments: [
    (SHError.errorDomain, SHError.Code.audioDiscontinuity.rawValue, RecognitionFailure.captureInterrupted),
    (NSURLErrorDomain, NSURLErrorTimedOut, .recognitionTimedOut),
    ("Resonance.Test", 42, .recognitionService(diagnostic: "Resonance.Test (42)")),
])
func translatesErrors(_ example: (domain: String, code: Int, expected: RecognitionFailure)) {
    let error = NSError(domain: example.domain, code: example.code)
    #expect(ShazamMetadata.failure(error) == example.expected)
}
