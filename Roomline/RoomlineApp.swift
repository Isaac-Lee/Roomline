import SwiftUI

@main
struct RoomlineApp: App {
    @State private var session = SessionController()

    var body: some Scene {
        MenuBarExtra("Roomline", systemImage: session.state == .recording ? "captions.bubble.fill" : "captions.bubble") {
            if let error = session.errorMessage {
                Text(error)
            }
            switch session.state {
            case .idle:
                Button("자막 시작") { Task { await session.start() } }
                    .keyboardShortcut("s")
            case .starting:
                Text("준비 중…")
            case .recording:
                Button("자막 중지") { Task { await session.stop() } }
                    .keyboardShortcut("s")
            }
            Divider()
            Toggle("자막 패널 보이기", isOn: $session.overlay.isVisible)
            Toggle("클릭 통과", isOn: $session.overlay.clickThrough)
            Divider()
            Button("종료") { NSApp.terminate(nil) }
                .keyboardShortcut("q")
        }
    }
}
