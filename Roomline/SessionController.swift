import AVFoundation
import CoreGraphics
import Observation
import Speech

enum SettingsKey {
    static let translateMine = "translateMine"
    static let echoGate = "echoGate"
    static let ollamaModel = "ollamaModel"
    static let defaultOllamaModel = "gemma3:12b"
}

/// 한 미팅의 생명주기: idle → starting → recording → finalizing(노트 생성) → idle
@MainActor @Observable
final class SessionController {
    enum State { case idle, starting, recording, finalizing }

    private(set) var state = State.idle
    private(set) var errorMessage: String?
    private(set) var notesProgress: String?
    /// 한국어 번역 언어팩이 없으면 자막만 띄우고 설치를 안내한다.
    private(set) var translationMissing = false
    /// 녹음 중 앱이 죽었거나 노트 생성이 실패한 미팅. 노트 생성을 다시 제안한다.
    private(set) var unfinishedMeetings: [MeetingRecord] = []
    var overlay = OverlayController()

    @ObservationIgnored private var capture: AudioCapture?
    @ObservationIgnored private var transcribers: [Speaker: Transcriber] = [:]
    @ObservationIgnored private var store: TranscriptStore?
    @ObservationIgnored private var updateTasks: [Task<Void, Never>] = []
    @ObservationIgnored private var translationTask: Task<Void, Never>?
    @ObservationIgnored private var hotKeys: HotKeys?

    init() {
        UserDefaults.standard.register(defaults: [
            SettingsKey.echoGate: false,
            SettingsKey.translateMine: false,
            SettingsKey.ollamaModel: SettingsKey.defaultOllamaModel,
        ])
        AVCaptureDevice.requestAccess(for: .audio) { _ in }
        refreshUnfinishedMeetings()
        hotKeys = makeHotKeys()
        Task { await refreshTranslationAvailability() }
    }

    func refreshTranslationAvailability() async {
        translationMissing = !(await AppleTranslator.isInstalled())
    }

    func refreshUnfinishedMeetings() {
        unfinishedMeetings = TranscriptStore.list().filter { $0.meta.state != .done }
    }

    // MARK: 미팅 시작

    func start() async {
        guard state == .idle else { return }
        errorMessage = nil
        guard CGPreflightScreenCaptureAccess() else {
            CGRequestScreenCaptureAccess()
            errorMessage = "시스템 설정 > 개인정보 보호 및 보안 > 화면 및 시스템 오디오 녹화에서 Roomline을 허용한 뒤 앱을 다시 실행하세요."
            return
        }
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else {
            errorMessage = "시스템 설정 > 개인정보 보호 및 보안 > 마이크에서 Roomline을 허용하세요."
            return
        }
        state = .starting
        overlay.clear()
        overlay.isVisible = true

        let defaults = UserDefaults.standard
        let translateMine = defaults.bool(forKey: SettingsKey.translateMine)
        let remote = AppleTranscriber()
        let me = AppleTranscriber()
        do {
            let format = try await remote.prepare()
            _ = try await me.prepare()
            let capture = AudioCapture(
                targetFormat: format,
                echoGate: defaults.bool(forKey: SettingsKey.echoGate),
                onBuffer: { speaker, buffer in (speaker == .remote ? remote : me).append(buffer) },
                onError: { [weak self] error in Task { @MainActor in await self?.captureFailed(error) } })
            try await capture.start()
            // 캡처가 실제로 시작된 뒤에 폴더를 만들어, 실패한 시작이 빈 미팅으로 남지 않게 한다.
            do {
                store = try TranscriptStore()
            } catch {
                await capture.stop()
                throw error
            }
            self.capture = capture
            transcribers = [.remote: remote, .me: me]
        } catch {
            await remote.finish()
            await me.finish()
            state = .idle
            errorMessage = error.localizedDescription
            return
        }

        await refreshTranslationAvailability()
        let (finals, finalsContinuation) = AsyncStream<Segment>.makeStream()
        translationTask = Task { [overlay, store, translationMissing] in
            let translator: Translator? = translationMissing ? nil : AppleTranslator()
            // 한 루프에서 하나씩 처리해 도착 순서대로 번역이 붙는다.
            for await segment in finals {
                guard let translator else { continue }
                do {
                    let text = try await translator.translate(segment.text)
                    overlay.setTranslation(text, for: segment.id)
                    await store?.append(.translation(segmentID: segment.id, text: text))
                } catch {
                    print("translation failed:", error)
                }
            }
        }

        updateTasks = transcribers.map { speaker, transcriber in
            Task { [overlay, store] in
                for await update in transcriber.updates {
                    switch update {
                    case .volatile(let text):
                        overlay.showVolatile(text, speaker: speaker)
                    case .final(let text, let start, let end):
                        let segment = Segment(id: UUID(), speaker: speaker, start: start, end: end, text: text)
                        overlay.appendFinal(segment)
                        await store?.append(.segment(segment))
                        if speaker == .remote || translateMine { finalsContinuation.yield(segment) }
                    }
                }
            }
        }
        // 두 채널이 다 끝나면 번역 큐도 닫는다.
        Task { [updateTasks] in
            for task in updateTasks { await task.value }
            finalsContinuation.finish()
        }
        state = .recording
    }

    // MARK: 미팅 종료 → 세션 해제 → 노트

    func stop() async {
        guard state == .recording else { return }
        state = .finalizing
        await capture?.stop()
        for transcriber in transcribers.values { await transcriber.finish() }
        for task in updateTasks { await task.value }
        await translationTask?.value
        capture = nil
        transcribers = [:]
        updateTasks = []
        translationTask = nil
        // 노트 생성용 LLM을 올리기 전에 음성 모델 메모리를 놓아준다.
        await SpeechModels.endRetention()

        guard let store else { state = .idle; return }
        self.store = nil
        await store.update {
            $0.endedAt = .now
            $0.state = .finalizing
        }
        await generateNotes(folder: store.folder)
    }

    func regenerateNotes(_ record: MeetingRecord) async {
        guard state == .idle else { return }
        state = .finalizing
        await generateNotes(folder: record.folder)
    }

    private func generateNotes(folder: URL) async {
        errorMessage = nil
        notesProgress = "노트 준비 중…"
        guard var meta = TranscriptStore.readMeta(in: folder) else {
            finishNotes()
            return
        }
        let lines = TranscriptStore.loadTranscript(in: folder)
        if meta.endedAt == nil {
            meta.endedAt = meta.startedAt.addingTimeInterval(lines.last?.segment.end ?? 0)
        }
        let model = UserDefaults.standard.string(forKey: SettingsKey.ollamaModel) ?? SettingsKey.defaultOllamaModel
        do {
            let notes = try await NotesGenerator(model: model).generate(meta: meta, lines: lines) { [weak self] progress in
                self?.notesProgress = progress
            }
            try notes.write(to: folder.appending(path: "notes.md"), atomically: true, encoding: .utf8)
            meta.state = .done
        } catch {
            meta.state = .failed
            errorMessage = "노트 생성 실패: \(error.localizedDescription)"
        }
        try? TranscriptStore.write(meta, to: folder)
        finishNotes()
    }

    private func finishNotes() {
        notesProgress = nil
        state = .idle
        refreshUnfinishedMeetings()
    }

    private func captureFailed(_ error: Error) async {
        await stop()
        errorMessage = "캡처가 중단됐습니다: \(error.localizedDescription)"
    }
}
