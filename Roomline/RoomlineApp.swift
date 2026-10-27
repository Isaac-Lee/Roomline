import Carbon.HIToolbox
import SwiftUI

@main
struct RoomlineApp: App {
    @State private var session = SessionController()

    var body: some Scene {
        MenuBarExtra {
            MenuContent(session: session)
        } label: {
            Image(systemName: session.state == .recording ? "captions.bubble.fill" : "captions.bubble")
        }
        Window("미팅 기록", id: "meetings") {
            MeetingsView(session: session)
        }
        Settings {
            SettingsView(session: session)
        }
    }
}

private struct MenuContent: View {
    @Bindable var session: SessionController
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        if let error = session.errorMessage {
            Text(error)
        }
        if session.translationMissing {
            Button("한국어 번역 언어팩 없음 — 설정에서 다운로드…") { showSettings() }
        }

        switch session.state {
        case .idle:
            Button("미팅 시작") { Task { await session.start() } }
                .keyboardShortcut("s", modifiers: [.control, .option])
        case .starting:
            Text("준비 중…")
        case .recording:
            Button("미팅 종료하고 노트 만들기") { Task { await session.stop() } }
                .keyboardShortcut("s", modifiers: [.control, .option])
        case .finalizing:
            Text(session.notesProgress ?? "정리 중…")
        }
        if session.state == .idle && !session.unfinishedMeetings.isEmpty {
            Menu("중단된 미팅 노트 만들기") {
                ForEach(session.unfinishedMeetings) { record in
                    Button(record.meta.title) { Task { await session.regenerateNotes(record) } }
                }
            }
        }

        Divider()
        Toggle("자막 패널 보이기", isOn: $session.overlay.isVisible)
            .keyboardShortcut("c", modifiers: [.control, .option])
        Toggle("클릭 통과", isOn: $session.overlay.clickThrough)
            .keyboardShortcut("x", modifiers: [.control, .option])
        Divider()
        Button("미팅 기록…") {
            NSApp.activate()
            openWindow(id: "meetings")
        }
        Button("설정…") { showSettings() }
            .keyboardShortcut(",")
        Button("종료") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }

    private func showSettings() {
        NSApp.activate()
        openSettings()
    }
}

extension SessionController {
    /// 메뉴에 표시된 것과 같은 ⌃⌥ 단축키를 전역으로 등록한다.
    func makeHotKeys() -> HotKeys {
        HotKeys([
            (kVK_ANSI_S, { [weak self] in
                guard let self else { return }
                Task {
                    switch self.state {
                    case .idle: await self.start()
                    case .recording: await self.stop()
                    default: break
                    }
                }
            }),
            (kVK_ANSI_C, { [weak self] in self?.overlay.isVisible.toggle() }),
            (kVK_ANSI_X, { [weak self] in self?.overlay.clickThrough.toggle() }),
        ])
    }
}
