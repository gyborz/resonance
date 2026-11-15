import SwiftUI

struct RecognitionPopover: View {
    @Environment(\.openSettings) private var openSettings

    let model: RecognitionPresentationModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            statusHeader
            if let track = model.track {
                TrackCard(track: track, isLatestMatch: model.isLatestMatch)
            }
            commands
        }
        .padding(18)
        .frame(width: 326)
    }

    private var statusHeader: some View {
        let status = model.status
        return HStack(alignment: .top, spacing: 10) {
            Group {
                if model.canCancel {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Image(systemName: status.icon)
                        .font(.title3)
                        .foregroundStyle(.tint)
                }
            }
            .frame(width: 22, height: 22)
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 4) {
                Text(status.title)
                    .font(.headline)
                if let detail = status.detail {
                    Text(detail)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            .accessibilityElement(children: .combine)
        }
    }

    private var commands: some View {
        VStack(spacing: 10) {
            if model.canCancel {
                Button {
                    Task { await model.cancel() }
                } label: {
                    Text("Cancel")
                        .frame(maxWidth: .infinity)
                }
                .keyboardShortcut(.cancelAction)
            } else {
                Button {
                    Task { await model.recognize() }
                } label: {
                    Text(model.recognizeTitle)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(!model.canRecognize)
                .keyboardShortcut(.defaultAction)
            }

            Divider()

            HStack {
                Button("Settings…") {
                    model.openSettings { openSettings() }
                }
                .keyboardShortcut(",", modifiers: .command)
                Spacer()
                Button("Quit") { model.quit() }
                    .keyboardShortcut("q", modifiers: .command)
            }
            .controlSize(.small)
        }
    }
}

private struct TrackCard: View {
    let track: TrackPresentation
    let isLatestMatch: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !isLatestMatch {
                Text("Last match")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 10) {
                artwork
                VStack(alignment: .leading, spacing: 3) {
                    Text(track.title)
                        .font(.headline)
                    Text(track.artist)
                        .foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine)
            }

            if let openAppleMusic = track.openAppleMusic {
                Button(action: openAppleMusic) {
                    Label("Open in Apple Music", systemImage: "arrow.up.right")
                }
                .controlSize(.small)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 12))
    }

    private var artwork: some View {
        AsyncImage(url: track.artworkURL) { phase in
            if let image = phase.image {
                image.resizable().scaledToFill()
            } else {
                Image(systemName: "music.note")
                    .font(.title2)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: 52, height: 52)
        .background(.quaternary)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .accessibilityHidden(true)
    }
}
