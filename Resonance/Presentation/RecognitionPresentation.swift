import Foundation
import Observation
import RecognitionCore

struct TrackPresentation {
    let title: String
    let artist: String
    let appleMusicURL: URL?
    let artworkURL: URL?
    let openAppleMusic: (@MainActor () -> Void)?

    @MainActor
    init(_ track: RecognizedTrack, urlOpener: any TrackURLOpening) {
        title = Self.cleaned(track.title) ?? String(localized: "Unknown song")
        artist = Self.cleaned(track.artist) ?? String(localized: "Unknown artist")
        appleMusicURL = Self.webURL(track.appleMusicURL)
        artworkURL = Self.webURL(track.artworkURL)
        if let appleMusicURL {
            openAppleMusic = { urlOpener.open(appleMusicURL) }
        } else {
            openAppleMusic = nil
        }
    }

    private static func cleaned(_ text: String?) -> String? {
        guard let text = text?.trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty else { return nil }
        return text
    }

    private static func webURL(_ url: URL?) -> URL? {
        guard let url, url.scheme?.lowercased() == "https",
              let host = url.host, !host.isEmpty,
              url.user == nil, url.password == nil else { return nil }
        return url
    }
}

struct RecognitionStatusPresentation {
    let title: LocalizedStringResource
    let detail: LocalizedStringResource?
    let icon: String

    init(_ snapshot: RecognitionSnapshot) {
        if snapshot.hasQueuedRetry {
            title = "Recognition queued"
            detail = "Waiting for the previous audio capture to stop."
            icon = "clock"
            return
        }
        switch snapshot.state {
        case .idle:
            title = "Ready to recognize"
            detail = nil
            icon = "waveform"
        case .starting:
            title = "Starting audio capture…"
            detail = "Follow any macOS permission prompt to continue."
            icon = "waveform"
        case .listening:
            title = "Listening…"
            detail = nil
            icon = "waveform.circle"
        case .searching:
            title = "Searching Shazam…"
            detail = nil
            icon = "magnifyingglass"
        case .matched:
            title = "Song found"
            detail = nil
            icon = "checkmark.circle"
        case .noMatch:
            title = "No song found"
            detail = "Try again during a clear part of the song."
            icon = "magnifyingglass"
        case .cancelled:
            title = "Recognition cancelled"
            detail = nil
            icon = "waveform"
        case .failed(let failure):
            icon = "exclamationmark.circle"
            switch failure {
            case .audioPermissionDenied:
                title = "System audio access is needed"
                detail = "Allow Resonance in System Settings → Privacy & Security → Screen & System Audio Recording, then try again."
            case .noAudio:
                title = "No audio received"
                detail = "Check that another app is playing audio and that Resonance has system audio access, then try again."
            case .silence:
                title = "Only silence received"
                detail = "Start playing the song in another app, then try again."
            case .captureInterrupted:
                title = "Audio capture was interrupted"
                detail = "Wait for playback to resume, then try again."
            case .captureUnavailable:
                title = "Couldn’t start audio capture"
                detail = "Check Resonance’s system audio access and try again."
            case .recognitionTimedOut:
                title = "Shazam took too long to respond"
                detail = "Check your connection and try again."
            case .recognitionService:
                title = "Shazam couldn’t identify the song"
                detail = "Check your connection and try again."
            }
        }
    }
}

@MainActor
@Observable
final class RecognitionPresentationModel {
    private(set) var snapshot = RecognitionSnapshot()
    private(set) var isExplaining = false
    private var recognitionSuspended = false

    @ObservationIgnored private let workflow: any RecognitionWorkflow
    @ObservationIgnored private let urlOpener: any TrackURLOpening
    @ObservationIgnored private let needsExplanation: @MainActor () -> Bool
    @ObservationIgnored private let explainSystemAudio: @MainActor () async -> Bool
    @ObservationIgnored private let markExplanationSeen: @MainActor () -> Void
    @ObservationIgnored private let quitApplication: @MainActor () -> Void
    @ObservationIgnored private var observation: Task<Void, Never>?
    @ObservationIgnored private var recognitionRequest: Task<Void, Never>?

    init(
        workflow: any RecognitionWorkflow,
        urlOpener: any TrackURLOpening,
        needsExplanation: @escaping @MainActor () -> Bool,
        explainSystemAudio: @escaping @MainActor () async -> Bool,
        markExplanationSeen: @escaping @MainActor () -> Void,
        quitApplication: @escaping @MainActor () -> Void
    ) {
        self.workflow = workflow
        self.urlOpener = urlOpener
        self.needsExplanation = needsExplanation
        self.explainSystemAudio = explainSystemAudio
        self.markExplanationSeen = markExplanationSeen
        self.quitApplication = quitApplication
    }

    deinit {
        observation?.cancel()
        recognitionRequest?.cancel()
    }

    var status: RecognitionStatusPresentation { RecognitionStatusPresentation(snapshot) }
    var track: TrackPresentation? {
        snapshot.lastTrack.map { TrackPresentation($0, urlOpener: urlOpener) }
    }
    var canRecognize: Bool { !recognitionSuspended && !snapshot.isActive && !isExplaining }
    var canCancel: Bool { snapshot.isActive }
    var isLatestMatch: Bool {
        if case .matched = snapshot.state { return true }
        return false
    }
    var recognizeTitle: LocalizedStringResource {
        switch snapshot.state {
        case .noMatch, .failed: "Try Again"
        default: "Recognize Song"
        }
    }

    /// Owned by application composition, independent of the menu bar window.
    func startObserving() {
        guard observation == nil else { return }
        observation = Task { [weak self, workflow] in
            for await snapshot in await workflow.updates() {
                guard let self, !Task.isCancelled else { return }
                apply(snapshot)
            }
        }
    }

    func apply(_ snapshot: RecognitionSnapshot) {
        self.snapshot = snapshot
    }

    func setRecognitionSuspended(_ suspended: Bool) {
        recognitionSuspended = suspended
        if suspended { recognitionRequest?.cancel() }
    }

    @discardableResult
    func requestRecognition() -> Task<Void, Never>? {
        guard canRecognize, recognitionRequest == nil else { return nil }
        let request = Task { [weak self] in
            guard let self else { return }
            defer { recognitionRequest = nil }
            await recognize()
        }
        recognitionRequest = request
        return request
    }

    private func recognize() async {
        guard canRecognize, !Task.isCancelled else { return }
        if needsExplanation() {
            isExplaining = true
            let agreed = await explainSystemAudio()
            isExplaining = false
            guard agreed, !Task.isCancelled else { return }
            markExplanationSeen()
        }
        await workflow.recognize()
    }

    func cancel() async {
        guard canCancel else { return }
        await workflow.cancel()
    }

    func openSettings(using action: @MainActor () -> Void) {
        action()
    }

    func quit() {
        quitApplication()
    }
}
