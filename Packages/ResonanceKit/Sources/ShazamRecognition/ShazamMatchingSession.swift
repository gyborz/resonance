import Foundation
import RecognitionCore
import ShazamKit

enum SignatureMatch: Equatable, Sendable {
    case match(RecognizedTrack)
    case noMatch
    case failure(RecognitionFailure)
}

/// The client actor owns the session; the callback carries only value types across isolation.
protocol SignatureMatchingSession: AnyObject {
    var minimumDuration: TimeInterval { get }
    var maximumDuration: TimeInterval { get }
    func match(_ signature: SHSignature, completion: @escaping @Sendable (SignatureMatch) -> Void)
    func invalidate()
}

final class ShazamMatchingSession: SignatureMatchingSession {
    private let session: SHSession
    private var relay: Delegate?

    init(customCatalogData: Data?) throws {
        if let customCatalogData {
            let catalog = try SHCustomCatalog(dataRepresentation: customCatalogData)
            session = SHSession(catalog: catalog)
        } else {
            session = SHSession()
        }
    }

    var minimumDuration: TimeInterval { session.catalog.minimumQuerySignatureDuration }
    var maximumDuration: TimeInterval { session.catalog.maximumQuerySignatureDuration }

    func match(_ signature: SHSignature, completion: @escaping @Sendable (SignatureMatch) -> Void) {
        let relay = Delegate(query: signature, completion: completion)
        self.relay = relay
        session.delegate = relay
        session.match(signature)
    }

    func invalidate() {
        session.delegate = nil
        relay = nil
    }

    private final class Delegate: NSObject, SHSessionDelegate {
        let query: SHSignature
        let completion: @Sendable (SignatureMatch) -> Void

        init(query: SHSignature, completion: @escaping @Sendable (SignatureMatch) -> Void) {
            self.query = query
            self.completion = completion
        }

        func session(_ session: SHSession, didFind match: SHMatch) {
            guard isCurrentQuery(match.querySignature) else { return }
            if let track = ShazamMetadata.firstTrack(in: match.mediaItems) {
                completion(.match(track))
            } else {
                completion(.failure(.recognitionService(diagnostic: "ShazamKit returned no usable media item")))
            }
        }

        func session(_ session: SHSession, didNotFindMatchFor signature: SHSignature, error: (any Error)?) {
            guard isCurrentQuery(signature) else { return }
            completion(ShazamMetadata.unmatchedResult(error: error))
        }

        private func isCurrentQuery(_ signature: SHSignature) -> Bool {
            signature === query || signature.dataRepresentation == query.dataRepresentation
        }
    }
}

enum ShazamMetadata {
    static func firstTrack(in items: [SHMediaItem], recognizedAt: Date = .now) -> RecognizedTrack? {
        var artworkOrLink: RecognizedTrack?
        var identifiedOnly: RecognizedTrack?
        for item in items {
            let title = text(item[.title])
            let artist = text(item[.artist])
            let appleMusicURL = item[.appleMusicURL] as? URL
            let artworkURL = item[.artworkURL] as? URL
            let identity = stableID(item)
            guard title != nil || artist != nil || appleMusicURL != nil || artworkURL != nil || identity != nil else {
                continue
            }
            let track = RecognizedTrack(
                id: identity ?? item.id.uuidString,
                title: title,
                artist: artist,
                appleMusicURL: appleMusicURL,
                artworkURL: artworkURL,
                recognizedAt: recognizedAt
            )
            if title != nil || artist != nil {
                return track
            }
            if appleMusicURL != nil || artworkURL != nil {
                artworkOrLink = artworkOrLink ?? track
            } else {
                identifiedOnly = identifiedOnly ?? track
            }
        }
        return artworkOrLink ?? identifiedOnly
    }

    static func unmatchedResult(error: (any Error)?) -> SignatureMatch {
        guard let error else { return .noMatch }

        let diagnostic = error as NSError
        if diagnostic.domain == SHError.errorDomain && diagnostic.code == SHError.Code.signatureInvalid.rawValue {
            // There is no usable fingerprint. The coordinator separately measures silence.
            return .noMatch
        }
        return .failure(failure(error))
    }

    static func failure(_ error: any Error) -> RecognitionFailure {
        if let failure = error as? RecognitionFailure { return failure }

        let diagnostic = error as NSError
        switch (diagnostic.domain, diagnostic.code) {
        case (SHError.errorDomain, SHError.Code.audioDiscontinuity.rawValue):
            return .captureInterrupted
        case (NSURLErrorDomain, NSURLErrorTimedOut):
            return .recognitionTimedOut
        default:
            return .recognitionService(diagnostic: "\(diagnostic.domain) (\(diagnostic.code))")
        }
    }

    private static func stableID(_ item: SHMediaItem) -> String? {
        if let id = text(item[.shazamID]) { return "shazam:\(id)" }
        if let id = text(item[.appleMusicID]) { return "apple-music:\(id)" }
        if let id = text(item.isrc) { return "isrc:\(id)" }
        return nil
    }

    private static func text(_ value: Any?) -> String? {
        guard let string = value as? String else { return nil }
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
