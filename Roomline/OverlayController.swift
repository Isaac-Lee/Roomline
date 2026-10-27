import AppKit
import SwiftUI

enum Speaker: String, Codable { case remote, me }

struct CaptionLine: Identifiable {
    let id = UUID()
    let speaker: Speaker
    let text: String
    var translation: String?
}

/// 화면 공유·녹화에서 빠지는 떠 있는 자막 패널.
@MainActor @Observable
final class OverlayController {
    private(set) var lines: [CaptionLine] = []
    private(set) var volatileText = ""

    var isVisible = true {
        didSet { isVisible ? panel.orderFrontRegardless() : panel.orderOut(nil) }
    }
    var clickThrough = false {
        didSet { panel.ignoresMouseEvents = clickThrough }
    }

    @ObservationIgnored private let panel: NSPanel
    private let maxLines = 4

    init() {
        let size = NSSize(width: 760, height: 300)
        let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let origin = NSPoint(x: screen.midX - size.width / 2, y: screen.minY + 40)
        panel = NSPanel(
            contentRect: NSRect(origin: origin, size: size),
            styleMask: [.borderless, .nonactivatingPanel, .resizable],
            backing: .buffered, defer: false)
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.sharingType = .none
        panel.isMovableByWindowBackground = true
        panel.hidesOnDeactivate = false
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.contentView = NSHostingView(rootView: CaptionsView(overlay: self))
        panel.orderFrontRegardless()
    }

    func showVolatile(_ text: String) {
        volatileText = text
    }

    func appendFinal(_ text: String, speaker: Speaker) -> CaptionLine.ID {
        volatileText = ""
        let line = CaptionLine(speaker: speaker, text: text)
        lines.append(line)
        if lines.count > maxLines { lines.removeFirst(lines.count - maxLines) }
        return line.id
    }

    func setTranslation(_ text: String, for id: CaptionLine.ID) {
        guard let index = lines.firstIndex(where: { $0.id == id }) else { return }
        lines[index].translation = text
    }

    func clear() {
        lines = []
        volatileText = ""
    }
}

private struct CaptionsView: View {
    let overlay: OverlayController

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(overlay.lines) { line in
                row(label: line.speaker == .remote ? "상대" : "나", text: line.text, color: .white,
                    translation: line.translation)
            }
            if !overlay.volatileText.isEmpty {
                row(label: "상대", text: overlay.volatileText, color: .gray, translation: nil)
            }
            if overlay.lines.isEmpty && overlay.volatileText.isEmpty {
                Text("자막 대기 중").foregroundStyle(.gray)
            }
        }
        .font(.system(size: 18))
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
        .padding(16)
        .background(.black.opacity(0.72), in: RoundedRectangle(cornerRadius: 12))
        .environment(\.colorScheme, .dark)
    }

    private func row(label: String, text: String, color: Color, translation: String?) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label).font(.system(size: 12, weight: .bold)).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(text).foregroundStyle(color)
                if let translation {
                    Text(translation).foregroundStyle(.yellow.opacity(0.9))
                }
            }
        }
    }
}
