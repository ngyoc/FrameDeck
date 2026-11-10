import SwiftUI

struct TransportBar: View {
    @ObservedObject var playback: PlaybackController
    @ObservedObject var model: PreviewModel

    var body: some View {
        ZStack {
            // 左右の操作群。中央は再生コントロール用に空けておく。
            HStack(spacing: 14) {
                timeReadout
                Spacer(minLength: 8)
                speedMenu
                audioControls
                waveformZoomControls
                waveformToggle
                exportButton
            }
            // 再生コントロールはバーの中央に固定する
            transportButtons
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(Color(red: 0.11, green: 0.11, blue: 0.13))
    }

    // MARK: - 送り戻し

    private var transportButtons: some View {
        HStack(spacing: 3) {
            iconButton("gobackward.10", help: "10 秒戻る（⇧⌥←）") { playback.skip(-10) }
            iconButton("gobackward.5", help: "5 秒戻る（⌥←）") { playback.skip(-5) }
            iconButton("backward.frame.fill", help: "1 フレーム戻る（←）") { playback.step(frames: -1) }

            Button {
                playback.togglePlay()
            } label: {
                Image(systemName: playback.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 15))
                    .frame(width: 34, height: 26)
            }
            .buttonStyle(.borderless)
            .help(playback.isPlaying ? "一時停止（Space）" : "再生（Space）")
            .disabled(!playback.isReady)

            iconButton("forward.frame.fill", help: "1 フレーム進む（→）") { playback.step(frames: 1) }
            iconButton("goforward.5", help: "5 秒進む（⌥→）") { playback.skip(5) }
            iconButton("goforward.10", help: "10 秒進む（⇧⌥→）") { playback.skip(10) }
        }
    }

    private func iconButton(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13))
                .frame(width: 28, height: 26)
        }
        .buttonStyle(.borderless)
        .help(help)
        .disabled(!playback.isReady)
    }

    // MARK: - 時間表示

    private var timeReadout: some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 6) {
                Text(playback.timecodeText)
                    .foregroundStyle(.primary)
                Text("/")
                    .foregroundStyle(.tertiary)
                Text(playback.durationTimecodeText)
                    .foregroundStyle(.secondary)
            }
            .font(.system(size: 12, weight: .medium, design: .monospaced))

            HStack(spacing: 6) {
                if playback.frameRate > 0 {
                    Text("フレーム \(playback.currentFrame) / \(playback.totalFrames)")
                }
                if playback.isVariableFrameRate {
                    Text("VFR")
                        .padding(.horizontal, 4)
                        .background(Color.orange.opacity(0.25), in: RoundedRectangle(cornerRadius: 3))
                        .help("可変フレームレートの可能性があります。フレーム番号は概算です")
                }
            }
            .font(.system(size: 10, design: .monospaced))
            .foregroundStyle(.secondary)
        }
        .fixedSize()
    }

    // MARK: - 速度・音量

    private var speedMenu: some View {
        Menu {
            ForEach(PlaybackController.speedPresets, id: \.self) { speed in
                Button {
                    playback.rate = speed
                } label: {
                    HStack {
                        Text(speedLabel(speed))
                        if playback.rate == speed { Image(systemName: "checkmark") }
                    }
                }
            }
        } label: {
            Text(speedLabel(playback.rate))
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .frame(width: 46)
        }
        .menuStyle(.borderlessButton)
        .frame(width: 66)
        .help("再生速度（[ で減速 / ] で加速 / \\ で 1x）")
    }

    private func speedLabel(_ value: Double) -> String {
        value == value.rounded() ? String(format: "%.0fx", value) : String(format: "%gx", value)
    }

    private var audioControls: some View {
        Button {
            playback.isMuted.toggle()
        } label: {
            Image(systemName: playback.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                .font(.system(size: 12))
                .frame(width: 26, height: 24)
        }
        .buttonStyle(.borderless)
        .help("ミュート（M）")
        .disabled(!playback.hasAudio)
    }

    private var waveformZoomControls: some View {
        HStack(spacing: 1) {
            Button { model.zoomWaveform(in: false) } label: {
                Image(systemName: "minus.magnifyingglass").font(.system(size: 12))
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.borderless)
            .help("波形をズームアウト（⌘-）")
            .disabled(!model.waveformViewport.isZoomed)

            Button { model.resetWaveformZoom() } label: {
                Text(model.waveformViewport.zoomLabel)
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .frame(minWidth: 34)
            }
            .buttonStyle(.borderless)
            .help("波形のズームをリセット（⌘0）")

            Button { model.zoomWaveform(in: true) } label: {
                Image(systemName: "plus.magnifyingglass").font(.system(size: 12))
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.borderless)
            .help("波形をズームイン（⌘+ / ピンチ / 横スクロールでパン）")
            .disabled(!playback.isReady)
        }
        .opacity(model.showWaveform ? 1 : 0.35)
        .disabled(!model.showWaveform)
    }

    private var waveformToggle: some View {
        Button {
            model.showWaveform.toggle()
        } label: {
            Image(systemName: "waveform")
                .font(.system(size: 12))
                .frame(width: 26, height: 24)
                .foregroundStyle(model.showWaveform ? Color.accentColor : Color.secondary)
        }
        .buttonStyle(.borderless)
        .help("オーディオ波形の表示切替（W）")
    }

    private var exportButton: some View {
        HStack(spacing: 4) {
            Button {
                model.openExportPanel()
            } label: {
                Image(systemName: model.colorAdjustments.isNeutral
                      ? "slider.horizontal.3" : "slider.horizontal.below.square.filled.and.square")
                    .font(.system(size: 12))
                    .frame(width: 26, height: 22)
                    .foregroundStyle(model.colorAdjustments.isNeutral ? Color.secondary : Color.accentColor)
            }
            .buttonStyle(.borderless)
            .help("色味を調整して書き出す（⌥S）")
            .disabled(!playback.isReady || !playback.hasVideo)

            Button {
                model.exportFrameQuick()
            } label: {
                HStack(spacing: 5) {
                    if model.isExporting {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "camera.fill").font(.system(size: 11))
                    }
                    Text("フレーム書き出し").font(.system(size: 11, weight: .medium))
                }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .help("現在のフレームを書き出し（S で即保存 / ⌥S で色味調整 / ⌘S で保存先を選ぶ）")
            .disabled(!playback.isReady || !playback.hasVideo || model.isExporting)
        }
    }
}
