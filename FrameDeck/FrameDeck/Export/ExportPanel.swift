import AppKit
import SwiftUI

/// フレーム書き出しパネル。現在のフレームを見ながら色味を決めて書き出す。
/// 調整は一時的なもので、元の動画ファイルには一切書き込まない。
struct ExportPanel: View {

    @ObservedObject var model: PreviewModel
    @ObservedObject var settings: AppSettings
    @ObservedObject var presets: ColorPresetStore
    let onClose: () -> Void

    @State private var sourceImage: CGImage?
    @State private var histogram: [Float] = []
    @State private var previewImage: NSImage?
    @State private var isRendering = false
    @State private var loadError: String?
    @State private var showBefore = false
    @State private var curveChannel: CurveChannel = .luma
    @State private var presetName = ""
    @State private var showPresetSheet = false
    @State private var renderTask: Task<Void, Never>?
    @AppStorage("export.curveHeight") private var curveHeight: Double = 240

    enum CurveChannel: String, CaseIterable, Identifiable {
        case luma, red, green, blue
        var id: String { rawValue }
        var label: String {
            switch self {
            case .luma: return "明るさ"
            case .red: return "R"
            case .green: return "G"
            case .blue: return "B"
            }
        }
        var tint: Color {
            switch self {
            case .luma: return .white
            case .red: return Color(red: 1, green: 0.35, blue: 0.35)
            case .green: return Color(red: 0.4, green: 0.9, blue: 0.45)
            case .blue: return Color(red: 0.4, green: 0.6, blue: 1)
            }
        }
    }

    var body: some View {
        HSplitView {
            previewPane
                .frame(minWidth: 420)
            controlPane
                .frame(width: 330)
        }
        .frame(minWidth: 820, minHeight: 560)
        .background(Color(red: 0.09, green: 0.09, blue: 0.11))
        .environment(\.colorScheme, .dark)
        .task(id: taskKey) { await loadSourceFrame() }
        // ウィンドウの閉じるボタンで閉じられたときも状態を合わせる
        .onDisappear { model.isExportPanelOpen = false }
        .onChange(of: model.colorAdjustments) { _, _ in scheduleRender() }
        .onChange(of: showBefore) { _, _ in scheduleRender() }
    }

    private var taskKey: String {
        "\(model.item?.url.path ?? "")|\(model.playback.currentTime)"
    }

    // MARK: - プレビュー

    private var previewPane: some View {
        VStack(spacing: 0) {
            ZStack {
                Color.black
                if let previewImage {
                    Image(nsImage: previewImage)
                        .resizable()
                        .interpolation(.high)
                        .scaledToFit()
                        .padding(14)
                } else if let loadError {
                    VStack(spacing: 10) {
                        Image(systemName: "exclamationmark.triangle")
                            .font(.system(size: 28)).foregroundStyle(.orange)
                        Text(loadError).font(.system(size: 12)).foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }.padding(30)
                } else {
                    ProgressView()
                }
                if isRendering {
                    ProgressView()
                        .controlSize(.small)
                        .padding(8)
                        .background(.thinMaterial, in: Circle())
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                        .padding(18)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            previewFooter
        }
    }

    private var previewFooter: some View {
        HStack(spacing: 12) {
            Button {
                showBefore.toggle()
            } label: {
                Label(showBefore ? "調整後を見る" : "調整前を見る",
                      systemImage: showBefore ? "eye" : "eye.slash")
                    .font(.system(size: 11))
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(model.colorAdjustments.isNeutral)

            Text(model.playback.timecodeText)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)

            if let image = sourceImage {
                // 桁区切りが入らないよう明示的に組み立てる
                Text(verbatim: "\(String(image.width))x\(String(image.height))")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if showBefore {
                Text("調整前を表示中")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.orange)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(Color(red: 0.11, green: 0.11, blue: 0.13))
    }

    // MARK: - 操作パネル

    private var controlPane: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(Color.white.opacity(0.08))
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    presetSection
                    Divider().overlay(Color.white.opacity(0.08))
                    basicSection(.color)
                    basicSection(.light)
                    Divider().overlay(Color.white.opacity(0.08))
                    curveSection
                    Divider().overlay(Color.white.opacity(0.08))
                    outputSection
                }
                .padding(14)
            }
            Divider().overlay(Color.white.opacity(0.08))
            footer
        }
        .background(Color(red: 0.10, green: 0.10, blue: 0.12))
    }

    private var header: some View {
        HStack {
            Text("フレーム書き出し")
                .font(.system(size: 13, weight: .semibold))
            Spacer()
            Button(action: onClose) { Image(systemName: "xmark") }
                .buttonStyle(.borderless)
                .help("閉じる（Esc）")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    // MARK: プリセット

    private var presetSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle("プリセット")
            HStack(spacing: 6) {
                Menu {
                    if presets.presets.isEmpty {
                        Text("保存されたプリセットはありません")
                    }
                    ForEach(presets.presets) { preset in
                        Button(preset.name) { model.colorAdjustments = preset.adjustments }
                    }
                    if !presets.presets.isEmpty {
                        Divider()
                        Menu("削除") {
                            ForEach(presets.presets) { preset in
                                Button(preset.name, role: .destructive) { presets.delete(preset) }
                            }
                        }
                    }
                } label: {
                    Label("読み込み", systemImage: "square.and.arrow.down")
                        .font(.system(size: 11))
                }
                .menuStyle(.borderlessButton)
                .frame(maxWidth: .infinity)

                Button {
                    presetName = ""
                    showPresetSheet = true
                } label: {
                    Label("保存", systemImage: "square.and.arrow.down.fill")
                        .font(.system(size: 11))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(model.colorAdjustments.isNeutral)
            }
        }
        .sheet(isPresented: $showPresetSheet) { presetSheet }
    }

    private var presetSheet: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("プリセットとして保存").font(.system(size: 13, weight: .semibold))
            TextField("名前（例: 屋内・暖色寄り）", text: $presetName)
                .textFieldStyle(.roundedBorder)
                .frame(width: 280)
            Text("同じ名前があれば上書きします。")
                .font(.system(size: 11)).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("キャンセル") { showPresetSheet = false }
                Button("保存") {
                    presets.save(name: presetName, adjustments: model.colorAdjustments)
                    showPresetSheet = false
                }
                .buttonStyle(.borderedProminent)
                .disabled(presetName.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
    }

    // MARK: 基本補正

    private func basicSection(_ section: ColorAdjustments.Field.Section) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                sectionTitle(section.label)
                Spacer()
                if section == .color {
                    Button("リセット") { model.colorAdjustments.resetBasics() }
                        .buttonStyle(.borderless)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
            }
            ForEach(ColorAdjustments.Field.allCases.filter { $0.section == section }) { field in
                slider(for: field)
            }
        }
    }

    private func slider(for field: ColorAdjustments.Field) -> some View {
        let binding = Binding(
            get: { model.colorAdjustments[field] },
            set: { model.colorAdjustments[field] = $0 }
        )
        let isNeutral = abs(binding.wrappedValue - field.neutralValue) < 0.0001
        return VStack(spacing: 1) {
            HStack {
                Text(field.label).font(.system(size: 11))
                Spacer()
                Text(String(format: "%.\(field.decimals)f", binding.wrappedValue))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(isNeutral ? .secondary : Color.accentColor)
                    .onTapGesture { binding.wrappedValue = field.neutralValue }
                    .help("クリックで初期値に戻す")
            }
            Slider(value: binding, in: field.range)
                .controlSize(.mini)
        }
    }

    // MARK: カーブ

    private var curveSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                sectionTitle("カラーカーブ")
                Spacer()
                Button("リセット") { model.colorAdjustments.resetCurves() }
                    .buttonStyle(.borderless)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
            Picker("", selection: $curveChannel) {
                ForEach(CurveChannel.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            ToneCurveEditor(curve: curveBinding, tint: curveChannel.tint, histogram: histogram)
                .frame(height: curveHeight)

            HStack(spacing: 8) {
                Text("クリックで点を追加 / ドラッグで移動 / ⌥クリックで削除")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                Spacer()
                Stepper("", value: $curveHeight, in: 160...420, step: 40)
                    .labelsHidden()
                    .controlSize(.mini)
                    .help("カーブの表示サイズ")
            }
        }
    }

    private var curveBinding: Binding<ToneCurve> {
        switch curveChannel {
        case .luma:  return $model.colorAdjustments.lumaCurve
        case .red:   return $model.colorAdjustments.redCurve
        case .green: return $model.colorAdjustments.greenCurve
        case .blue:  return $model.colorAdjustments.blueCurve
        }
    }

    // MARK: 出力

    private var outputSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle("出力")

            Picker("形式", selection: Binding(
                get: { settings.exportFormat }, set: { settings.exportFormat = $0 })) {
                ForEach(ImageFormat.allCases) { Text($0.label).tag($0) }
            }
            .controlSize(.small)

            if settings.exportFormat == .jpeg {
                VStack(spacing: 1) {
                    HStack {
                        Text("品質").font(.system(size: 11))
                        Spacer()
                        Text(String(format: "%.0f", settings.jpegQuality * 100))
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                    Slider(value: $settings.jpegQuality, in: 0.3...1.0).controlSize(.mini)
                }
            }

            Picker("サイズ", selection: $settings.longestEdge) {
                Text("原寸").tag(0)
                Text("長辺 3840").tag(3840)
                Text("長辺 2560").tag(2560)
                Text("長辺 1920").tag(1920)
                Text("長辺 1280（YouTube サムネ）").tag(1280)
            }
            .controlSize(.small)

            Picker("保存先", selection: Binding(
                get: { settings.destinationMode }, set: { settings.destinationMode = $0 })) {
                ForEach(ExportDestinationMode.allCases) { Text($0.label).tag($0) }
            }
            .controlSize(.small)

            if settings.destinationMode == .fixedFolder {
                HStack(spacing: 6) {
                    Text(settings.fixedDestination.lastPathComponent)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.head)
                    Spacer()
                    Button("選択…") { chooseFolder() }
                        .buttonStyle(.bordered).controlSize(.mini)
                }
            }

            if let destination = destinationPreview {
                Text(destination)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .padding(.top, 2)
            }
        }
    }

    private var destinationPreview: String? {
        guard let item = model.item else { return nil }
        let dir = settings.exportDestination(for: item.url)
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let shown = dir.path.hasPrefix(home) ? "~" + dir.path.dropFirst(home.count) : dir.path
        return "書き出し先: \(shown)/"
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = settings.fixedDestination
        if panel.runModal() == .OK, let url = panel.url {
            settings.fixedDestination = url
        }
    }

    // MARK: フッター

    private var footer: some View {
        HStack(spacing: 8) {
            Button("色味をリセット") {
                model.colorAdjustments = .neutral
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(model.colorAdjustments.isNeutral)

            Spacer()

            Button {
                model.exportFrameQuick()
            } label: {
                HStack(spacing: 5) {
                    if model.isExporting {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "camera.fill").font(.system(size: 11))
                    }
                    Text("書き出す").font(.system(size: 12, weight: .medium))
                }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.regular)
            .keyboardShortcut(.return, modifiers: [])
            .disabled(model.isExporting || sourceImage == nil)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private func sectionTitle(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.secondary)
            .textCase(.uppercase)
    }

    // MARK: - フレームの取得と描画

    private func loadSourceFrame() async {
        guard let item = model.item, item.kind == .video else {
            loadError = "動画を表示しているときだけ使えます"
            return
        }
        sourceImage = nil
        previewImage = nil
        loadError = nil
        do {
            // プレビュー用途なので長辺 2048 に抑える。書き出しは常に原寸から作り直す。
            let image = try await FrameExporter.makeFrameImage(
                assetURL: item.url,
                at: model.playback.currentTime,
                maximumSize: CGSize(width: 2048, height: 2048))
            sourceImage = image
            histogram = await Task.detached(priority: .utility) {
                FrameExporter.luminanceHistogram(image)
            }.value
            render()
        } catch {
            loadError = error.localizedDescription
            Log.export.error("プレビューのフレーム取得に失敗: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func scheduleRender() {
        renderTask?.cancel()
        renderTask = Task { @MainActor in
            // スライダーを動かしている間に描き直しが詰まらないよう少し待つ
            try? await Task.sleep(for: .milliseconds(40))
            guard !Task.isCancelled else { return }
            render()
        }
    }

    private func render() {
        guard let source = sourceImage else { return }
        if showBefore || model.colorAdjustments.isNeutral {
            previewImage = NSImage(cgImage: source, size: .zero)
            isRendering = false
            return
        }
        isRendering = true
        let adjustments = model.colorAdjustments
        Task { @MainActor in
            let rendered = await Task.detached(priority: .userInitiated) {
                FrameExporter.adjusted(source, with: adjustments)
            }.value
            if let rendered {
                previewImage = NSImage(cgImage: rendered, size: .zero)
            }
            isRendering = false
        }
    }
}
