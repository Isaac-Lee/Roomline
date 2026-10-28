import AppIntents

/// Siri·단축어: "Roomline으로 미팅 시작/종료", "Roomline 액션아이템".
struct StartMeetingIntent: AppIntent {
    static let title: LocalizedStringResource = "미팅 시작"
    @Dependency var session: SessionController

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        await session.start()
        return .result(dialog: IntentDialog(stringLiteral: session.errorMessage ?? (session.state == .recording ? "미팅을 시작했습니다." : "미팅을 시작하지 못했습니다.")))
    }
}

struct StopMeetingIntent: AppIntent {
    static let title: LocalizedStringResource = "미팅 종료"
    @Dependency var session: SessionController

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard session.state == .recording else { return .result(dialog: "진행 중인 미팅이 없습니다.") }
        await session.stop()
        return .result(dialog: "미팅을 종료했습니다. 노트는 잠시 뒤 만들어집니다.")
    }
}

struct LastActionItemsIntent: AppIntent {
    static let title: LocalizedStringResource = "마지막 미팅 액션아이템"

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let notes = TranscriptStore.list().lazy
            .compactMap { try? String(contentsOf: $0.notesURL, encoding: .utf8) }
            .first
        guard let notes else { return .result(dialog: "아직 만들어진 노트가 없습니다.") }
        return .result(dialog: IntentDialog(stringLiteral: NotesGenerator.actionItems(in: notes)))
    }
}

struct RoomlineShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: StartMeetingIntent(), phrases: ["\(.applicationName)으로 미팅 시작", "\(.applicationName) 미팅 시작"],
                    shortTitle: "미팅 시작", systemImageName: "record.circle")
        AppShortcut(intent: StopMeetingIntent(), phrases: ["\(.applicationName) 미팅 종료", "\(.applicationName)으로 미팅 끝내기"],
                    shortTitle: "미팅 종료", systemImageName: "stop.circle")
        AppShortcut(intent: LastActionItemsIntent(), phrases: ["\(.applicationName) 액션아이템", "\(.applicationName) 마지막 미팅 할 일"],
                    shortTitle: "액션아이템", systemImageName: "checklist")
    }
}
