import Foundation

struct ColorPreset: Codable, Identifiable, Equatable {
    var id: UUID = UUID()
    var name: String
    var adjustments: ColorAdjustments
    var createdAt: Date = Date()
}

/// 色味調整のプリセット。Application Support に JSON で置く。
@MainActor
final class ColorPresetStore: ObservableObject {

    @Published private(set) var presets: [ColorPreset] = []

    private static var fileURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
        return base
            .appendingPathComponent("FrameDeck", isDirectory: true)
            .appendingPathComponent("color-presets.json")
    }

    init() {
        load()
    }

    func load() {
        guard let data = try? Data(contentsOf: ColorPresetStore.fileURL) else { return }
        do {
            presets = try JSONDecoder().decode([ColorPreset].self, from: data)
        } catch {
            Log.export.error("プリセットを読めません: \(error.localizedDescription, privacy: .public)")
        }
    }

    func save(name: String, adjustments: ColorAdjustments) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if let index = presets.firstIndex(where: { $0.name == trimmed }) {
            presets[index].adjustments = adjustments
        } else {
            presets.append(ColorPreset(name: trimmed, adjustments: adjustments))
        }
        persist()
    }

    func delete(_ preset: ColorPreset) {
        presets.removeAll { $0.id == preset.id }
        persist()
    }

    func rename(_ preset: ColorPreset, to newName: String) {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let index = presets.firstIndex(where: { $0.id == preset.id }) else { return }
        presets[index].name = trimmed
        persist()
    }

    private func persist() {
        do {
            try FileManager.default.createDirectory(
                at: ColorPresetStore.fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(presets).write(to: ColorPresetStore.fileURL, options: .atomic)
        } catch {
            Log.export.error("プリセットを保存できません: \(error.localizedDescription, privacy: .public)")
        }
    }
}
