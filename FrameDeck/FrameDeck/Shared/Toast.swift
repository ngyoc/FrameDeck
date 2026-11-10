import SwiftUI

struct ToastMessage: Identifiable, Equatable {
    enum Style { case info, success, failure }

    let id = UUID()
    var text: String
    var detail: String?
    var style: Style = .info
    /// 「Finder で表示」など、トーストから直接叩きたい導線
    var revealURL: URL?

    static func == (lhs: ToastMessage, rhs: ToastMessage) -> Bool { lhs.id == rhs.id }
}

struct ToastView: View {
    let message: ToastMessage
    let onDismiss: () -> Void

    private var symbol: String {
        switch message.style {
        case .info:    return "info.circle.fill"
        case .success: return "checkmark.circle.fill"
        case .failure: return "exclamationmark.triangle.fill"
        }
    }

    private var tint: Color {
        switch message.style {
        case .info:    return .accentColor
        case .success: return .green
        case .failure: return .red
        }
    }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .foregroundStyle(tint)
                .font(.system(size: 15, weight: .semibold))
            VStack(alignment: .leading, spacing: 2) {
                Text(message.text).font(.system(size: 12, weight: .medium))
                if let detail = message.detail {
                    Text(detail)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            if let url = message.revealURL {
                Divider().frame(height: 22)
                Button("Finder で表示") {
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                    onDismiss()
                }
                .buttonStyle(.link)
                .font(.system(size: 11))
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(.white.opacity(0.12)))
        .shadow(color: .black.opacity(0.3), radius: 12, y: 4)
        .onTapGesture(perform: onDismiss)
    }
}

@MainActor
final class ToastCenter: ObservableObject {
    @Published var message: ToastMessage?
    private var dismissTask: Task<Void, Never>?

    func show(_ message: ToastMessage, duration: Double = 3.5) {
        dismissTask?.cancel()
        self.message = message
        dismissTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(duration))
            guard !Task.isCancelled else { return }
            self?.message = nil
        }
    }

    func dismiss() {
        dismissTask?.cancel()
        message = nil
    }
}
