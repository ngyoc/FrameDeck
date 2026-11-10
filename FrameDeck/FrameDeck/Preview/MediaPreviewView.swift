import SwiftUI

/// 動画と音声で共通のプレビュー本体。
/// 音声ファイルのときは映像領域を波形の大型表示に置き換える。
struct MediaPreviewView: View {
    @ObservedObject var model: PreviewModel
    @ObservedObject private var playback: PlaybackController
    @ObservedObject private var waveform: WaveformLoader

    init(model: PreviewModel) {
        self.model = model
        self.playback = model.playback
        self.waveform = model.waveform
    }

    @State private var waveformWidth: CGFloat = 1

    var body: some View {
        VStack(spacing: 0) {
            stage
            if model.showWaveform || !playback.hasVideo {
                waveformStrip
                    .frame(height: playback.hasVideo ? 104 : 240)
            }
            TransportBar(playback: playback, model: model)
        }
        .background(Color.black)
        .onChange(of: playback.duration) { _, newValue in
            model.syncWaveformViewport(duration: newValue)
        }
        .onChange(of: playback.currentTime) { _, newValue in
            model.waveformViewport.follow(newValue)
        }
    }

    // MARK: - 映像

    @ViewBuilder
    private var stage: some View {
        ZStack {
            Color.black
            if let error = playback.loadError {
                VStack(spacing: 12) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 30))
                        .foregroundStyle(.orange)
                    Text(error)
                        .font(.system(size: 12))
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.secondary)
                }
                .padding(30)
            } else if playback.hasVideo {
                PlayerLayerRenderer().makeView(player: playback.player)
                    .onTapGesture { playback.togglePlay() }
            } else if playback.isReady {
                VStack(spacing: 10) {
                    Image(systemName: "waveform")
                        .font(.system(size: 40))
                        .foregroundStyle(.secondary)
                    Text("音声ファイル")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
            } else {
                ProgressView()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - 波形

    private var waveformStrip: some View {
        WaveformView(
            data: waveform.data,
            duration: playback.duration,
            currentTime: playback.currentTime,
            isAnalyzing: waveform.isAnalyzing,
            errorMessage: waveformMessage,
            viewport: $model.waveformViewport,
            onScrub: { time in playback.scrub(to: time) },
            onScrubEnded: { time in playback.endScrub(to: time) }
        )
        .background(
            GeometryReader { geo in
                Color.clear
                    .onAppear { waveformWidth = geo.size.width }
                    .onChange(of: geo.size.width) { _, newValue in waveformWidth = newValue }
            }
        )
        .onAppear { model.waveformViewWidth = waveformWidth }
        .onChange(of: waveformWidth) { _, newValue in model.waveformViewWidth = newValue }
    }

    private var waveformMessage: String? {
        if let error = waveform.errorMessage { return error }
        if playback.isReady, !playback.hasAudio { return "この素材に音声トラックはありません" }
        return nil
    }
}
