import AppKit
import SwiftUI

struct CaptionLine: Identifiable {
    let id: UUID
    let speaker: Speaker
    let text: String
    var translation: String?
}

/// 화면 공유·녹화에서 빠지는 떠 있는 자막 패널.
@MainActor @Observable
final class OverlayController {
    private(set) var lines: [CaptionLine] = []
    /// 화자별 확정 전 미리보기
    private(set) var volatileText: [Speaker: String] = [:]

    var isVisible = true {
        didSet { isVisible ? panel.orderFrontRegardless() : panel.orderOut(nil) }
    }
    var clickThrough = UserDefaults.standard.bool(forKey: "overlay.clickThrough") {
        didSet {
            panel.ignoresMouseEvents = clickThrough
            UserDefaults.standard.set(clickThrough, forKey: "overlay.clickThrough")
        }
    }
    var fontSize = UserDefaults.standard.object(forKey: "overlay.fontSize") as? Double ?? 18 {
        didSet { UserDefaults.standard.set(fontSize, forKey: "overlay.fontSize") }
    }
    var backgroundOpacity = UserDefaults.standard.object(forKey: "overlay.opacity") as? Double ?? 0.72 {
        didSet { UserDefaults.standard.set(backgroundOpacity, forKey: "overlay.opacity") }
    }

    @ObservationIgnored private let panel: NSPanel
    private let maxLines = 4

    init() {
        let size = NSSize(width: 760, height: 300)
        let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let origin = NSPoint(x: screen.midX - size.width / 2, y: screen.minY + 40)
        panel = CaptionsPanel(
            contentRect: NSRect(origin: origin, size: size),
            styleMask: [.borderless, .nonactivatingPanel, .resizable],
            backing: .buffered, defer: false)
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.sharingType = .none
        panel.hidesOnDeactivate = false
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.ignoresMouseEvents = clickThrough
        panel.setFrameAutosaveName("CaptionsPanel")
        panel.contentView = NSHostingView(rootView: CaptionsView(overlay: self))
        panel.orderFrontRegardless()
    }

    func showVolatile(_ text: String, speaker: Speaker) {
        volatileText[speaker] = text
    }

    func appendFinal(_ segment: Segment) {
        volatileText[segment.speaker] = nil
        lines.append(CaptionLine(id: segment.id, speaker: segment.speaker, text: segment.text))
        if lines.count > maxLines { lines.removeFirst(lines.count - maxLines) }
    }

    func setTranslation(_ text: String, for id: CaptionLine.ID) {
        guard let index = lines.firstIndex(where: { $0.id == id }) else { return }
        lines[index].translation = text
    }

    func clear() {
        lines = []
        volatileText = [:]
    }
}

/// SwiftUI 뷰가 마우스를 먹어 isMovableByWindowBackground가 안 먹히므로 창에서 직접 끌어서 옮긴다.
/// 가장자리 8pt는 크기 조절용으로 남긴다.
private final class CaptionsPanel: NSPanel {
    override func sendEvent(_ event: NSEvent) {
        if event.type == .leftMouseDown,
           NSRect(origin: .zero, size: frame.size).insetBy(dx: 8, dy: 8).contains(event.locationInWindow) {
            performDrag(with: event)
            return
        }
        super.sendEvent(event)
    }
}

private struct CaptionsView: View {
    let overlay: OverlayController

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(overlay.lines) { line in
                row(label: label(line.speaker), text: line.text, color: .white,
                    translation: line.translation)
            }
            ForEach([Speaker.remote, .me], id: \.self) { speaker in
                if let text = overlay.volatileText[speaker], !text.isEmpty {
                    row(label: label(speaker), text: text, color: .gray, translation: nil)
                }
            }
            if overlay.lines.isEmpty && overlay.volatileText.values.allSatisfy(\.isEmpty) {
                Text("자막 대기 중").foregroundStyle(.gray)
            }
        }
        .font(.system(size: overlay.fontSize))
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
        .padding(16)
        .background(.black.opacity(overlay.backgroundOpacity), in: RoundedRectangle(cornerRadius: 12))
        .environment(\.colorScheme, .dark)
    }

    private func label(_ speaker: Speaker) -> String {
        speaker == .remote ? "상대" : "나"
    }

    private func row(label: String, text: String, color: Color, translation: String?) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label).font(.system(size: overlay.fontSize * 0.65, weight: .bold)).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(text).foregroundStyle(color)
                if let translation {
                    Text(translation).foregroundStyle(.yellow.opacity(0.9))
                }
            }
        }
    }
}
