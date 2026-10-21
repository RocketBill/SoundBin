import SwiftUI

/// Floating glass bar for the current sound, always shown; before anything plays it sits empty.
/// Pieces that change every frame are split into their own views so only they redraw during playback.
struct TransportBar: View {
    @Environment(AppModel.self) private var model
    @State private var artwork: CGImage?

    var body: some View {
        let player = model.player
        let file = player.currentFile
        HStack(spacing: 14) {
            PlayPauseButton(model: model, player: player)

            if let artwork, file != nil {
                Image(decorative: artwork, scale: 1)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 36, height: 36)
                    .clipShape(.rect(cornerRadius: 6))
                    .padding(.trailing, -4)
            }

            VStack(alignment: .leading, spacing: 1) {
                Text(file.map(model.name(of:)) ?? "Not Playing")
                    .font(.headline)
                    .foregroundStyle(file == nil ? .secondary : .primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(file.map(details) ?? "Click a sound to play it")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .frame(width: 180, alignment: .leading)

            HStack(spacing: 10) {
                ElapsedLabel(player: player)
                WaveformScrubber(file: file, player: player, waveforms: model.waveforms)
                    .frame(height: 30)
                Text(Format.position(player.duration, total: player.duration))
                    .frame(width: 44, alignment: .leading)
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)

            LoopToggle(player: player)
            PlayNextToggle(player: player)
            VolumeControl(player: player)
        }
        .padding(.leading, 8)
        .padding(.trailing, 18)
        .padding(.vertical, 8)
        .frame(maxWidth: 1000)
        // The whole bar takes clicks, so none fall through its gaps to the tiles scrolling underneath.
        .contentShape(.capsule)
        .glassEffect(.regular, in: .capsule)
        .task(id: model.showsArtwork ? file.map(FileKey.init) : nil) {
            artwork = if model.showsArtwork, let file { await model.artworks.value(for: file).image } else { nil }
        }
    }

    private func details(for file: AudioFile) -> String {
        let folder = file.folder.isEmpty ? model.rootTitle : file.folder.replacingOccurrences(of: "/", with: " › ")
        let channels = file.channelCount == 1 ? "Mono" : (file.channelCount == 2 ? "Stereo" : "\(file.channelCount) ch")
        return [folder, file.formatName, Format.sampleRate(file.sampleRate), channels].joined(separator: " · ")
    }
}

private struct PlayPauseButton: View {
    let model: AppModel
    let player: AudioPlayer

    var body: some View {
        Button {
            // Before anything has played, the button starts the selected sound.
            if player.currentFile == nil, let file = model.selectedFiles.first {
                model.play(file)
            } else {
                player.togglePlayPause()
            }
        } label: {
            Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                .font(.system(size: 16, weight: .semibold))
                .contentTransition(.symbolEffect(.replace))
                .frame(width: 36, height: 36)
        }
        .buttonStyle(.glassProminent)
        .buttonBorderShape(.circle)
        .disabled(player.currentFile == nil && model.selection.isEmpty)
        .help(player.isPlaying ? "Pause" : "Play")
    }
}

private struct ElapsedLabel: View {
    let player: AudioPlayer

    var body: some View {
        Text(Format.position(player.currentTime, total: player.duration))
            .frame(width: 44, alignment: .trailing)
    }
}

private struct LoopToggle: View {
    @Bindable var player: AudioPlayer

    var body: some View {
        Toggle(isOn: $player.isLooping) {
            Image(systemName: "repeat")
        }
        .toggleStyle(.button)
        .buttonStyle(.borderless)
        .foregroundStyle(player.isLooping ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
        .help(player.isLooping ? "Looping" : "Loop")
    }
}

private struct PlayNextToggle: View {
    @Bindable var player: AudioPlayer

    var body: some View {
        Toggle(isOn: $player.playsNext) {
            Image(systemName: "text.line.first.and.arrowtriangle.forward")
        }
        .toggleStyle(.button)
        .buttonStyle(.borderless)
        .foregroundStyle(player.playsNext ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
        .help(player.playsNext ? "Playing Next Sound Automatically" : "Play Next Sound Automatically")
    }
}

private struct VolumeControl: View {
    @Bindable var player: AudioPlayer

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "speaker.wave.2.fill", variableValue: player.volume)
                .foregroundStyle(.secondary)
                .frame(width: 18)
            Slider(value: $player.volume, in: 0...1)
                .controlSize(.small)
                .frame(width: 84)
        }
        .help("Volume")
    }
}

/// The current sound's waveform; click or drag anywhere on it to jump. Placeholder dashes when nothing's loaded.
private struct WaveformScrubber: View {
    let file: AudioFile?
    let player: AudioPlayer
    let waveforms: BackgroundLoader<Waveform>

    @State private var waveform: Waveform?
    @State private var dragProgress: Double?

    var body: some View {
        GeometryReader { proxy in
            Canvas { context, size in
                let rect = CGRect(origin: .zero, size: size).insetBy(dx: 0, dy: 3)
                let bars = Path(WaveformPath.make(waveform, in: rect))
                let progress = dragProgress ?? player.progress
                let playheadX = (size.width * progress).rounded()

                context.fill(bars, with: .style(.secondary.opacity(0.7)))
                var played = context
                played.clip(to: Path(CGRect(x: 0, y: 0, width: playheadX, height: size.height)))
                played.fill(bars, with: .style(.tint))
                if progress > 0 {
                    context.fill(Path(CGRect(x: playheadX - 0.75, y: 0, width: 1.5, height: size.height)),
                                 with: .style(.primary))
                }
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        dragProgress = fraction(value.location.x, width: proxy.size.width)
                    }
                    .onEnded { value in
                        player.seek(to: fraction(value.location.x, width: proxy.size.width) * player.duration)
                        dragProgress = nil
                    }
            )
            .allowsHitTesting(file != nil)
        }
        .task(id: file.map(FileKey.init)) {
            waveform = nil
            if let file { waveform = await waveforms.value(for: file) }
        }
        .accessibilityElement()
        .accessibilityLabel("Playback position")
        .accessibilityValue(Format.position(player.currentTime, total: player.duration))
        .accessibilityAdjustableAction { direction in
            let step = max(1, player.duration / 20)
            player.seek(to: player.currentTime + (direction == .increment ? step : -step))
        }
    }

    private func fraction(_ x: CGFloat, width: CGFloat) -> Double {
        guard width > 0 else { return 0 }
        return min(1, max(0, Double(x / width)))
    }
}
