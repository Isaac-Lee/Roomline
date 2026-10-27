import AVFoundation
import Observation
import ScreenCaptureKit
import Speech

enum SettingsKey {
    static let translateMine = "translateMine"
    static let echoGate = "echoGate"
    static let remoteLocale = "remoteLocale"
    static let meetingLanguage = "meetingLanguage"  // "en" | "ko"
    static let ollamaModel = "ollamaModel"
    static let defaultOllamaModel = "gemma3:12b"
}

/// 한 미팅의 생명주기: idle → starting → recording → finalizing(세션 해제) → idle. 노트 생성은 백그라운드 큐가 따로 처리한다.
@MainActor @Observable
final class SessionController {
    enum State { case idle, starting, recording, finalizing }

    private(set) var state = State.idle
    private(set) var errorMessage: String?
    private(set) var notesProgress: String?
    /// 지금 노트를 만드는 미팅 폴더. 큐에서 하나씩만 처리한다.
    private(set) var notesJob: URL?
    @ObservationIgnored private var notesTitle = ""
    @ObservationIgnored private var pendingNotes: [(folder: URL, diarize: Bool)] = []
    @ObservationIgnored private var notesWorker: Task<Void, Never>?
    /// 한국어 번역 언어팩이 없으면 자막만 띄우고 설치를 안내한다.
    private(set) var translationMissing = false
    /// 녹음 중 앱이 죽었거나 노트 생성이 실패한 미팅. 노트 생성을 다시 제안한다.
    private(set) var unfinishedMeetings: [MeetingRecord] = []
    var overlay = OverlayController()

    @ObservationIgnored private var capture: AudioCapture?
    @ObservationIgnored private var transcribers: [Speaker: Transcriber] = [:]
    @ObservationIgnored private var store: TranscriptStore?
    @ObservationIgnored private var remoteRecorder: RemoteAudioRecorder?
    @ObservationIgnored private var updateTasks: [Task<Void, Never>] = []
    @ObservationIgnored private var translationTask: Task<Void, Never>?
    @ObservationIgnored private var hotKeys: HotKeys?
    /// 최근 remote final (에코 판별용, 도착 시각 기준 ~15초만 유지)
    @ObservationIgnored private var recentRemote: [(text: String, at: Date)] = []

    init() {
        UserDefaults.standard.register(defaults: [
            SettingsKey.echoGate: "auto",
            SettingsKey.remoteLocale: "en-US",
            SettingsKey.meetingLanguage: "en",
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
        // 마이크 권한이 미결정이면 먼저 요청한다.
        if AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
            _ = await AVCaptureDevice.requestAccess(for: .audio)
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
        // 한국어 미팅이면 양쪽 모두 ko-KR, 번역은 하지 않는다.
        let korean = defaults.string(forKey: SettingsKey.meetingLanguage) == "ko"
        let remote = AppleTranscriber(locale: Locale(identifier: korean ? "ko-KR" : defaults.string(forKey: SettingsKey.remoteLocale) ?? "en-US"))
        let me = AppleTranscriber(locale: Locale(identifier: korean ? "ko-KR" : "en-US"))
        var newStore: TranscriptStore?
        do {
            let format = try await remote.prepare()
            _ = try await me.prepare()
            let store = try TranscriptStore()
            newStore = store
            // 미팅 후 화자 구분용. 녹음 실패는 자막을 막지 않는다.
            let recorder = try? RemoteAudioRecorder(folder: store.folder, format: format)
            let capture = AudioCapture(
                targetFormat: format,
                echoMode: defaults.string(forKey: SettingsKey.echoGate) ?? "auto",
                onBuffer: { speaker, buffer in
                    if speaker == .remote {
                        recorder?.append(buffer)
                        remote.append(buffer)
                    } else {
                        me.append(buffer)
                    }
                },
                onError: { [weak self] error in Task { @MainActor in await self?.captureFailed(error) } })
            try await capture.start()
            self.store = store
            self.remoteRecorder = recorder
            self.capture = capture
            transcribers = [.remote: remote, .me: me]
        } catch {
            await remote.finish()
            await me.finish()
            // 실패한 시작이 빈 미팅으로 남지 않게 지운다.
            if let folder = newStore?.folder { try? FileManager.default.removeItem(at: folder) }
            state = .idle
            // 화면 녹화 권한은 캡처 시작 시 시스템이 묻고, 거부되면 여기로 온다.
            let e = error as NSError
            errorMessage = e.domain == SCStreamErrorDomain && e.code == SCStreamError.userDeclined.rawValue
                ? "시스템 설정 > 개인정보 보호 및 보안 > 화면 및 시스템 오디오 녹화에서 Roomline을 허용한 뒤 앱을 다시 실행하세요."
                : error.localizedDescription
            return
        }

        await refreshTranslationAvailability()
        let (finals, finalsContinuation) = AsyncStream<Segment>.makeStream()
        translationTask = Task { [overlay, store, translationMissing] in
            let translator: Translator? = translationMissing || korean ? nil : AppleTranslator()
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
            Task { [weak self, overlay, store] in
                @MainActor func commit(_ segment: Segment) async {
                    overlay.appendFinal(segment)
                    await store?.append(.segment(segment))
                    if speaker == .remote || translateMine { finalsContinuation.yield(segment) }
                }
                // 보류 중인 me 세그먼트까지 끝나야 이 Task가 끝나므로 종료 때 마지막 문장도 저장된다.
                await withDiscardingTaskGroup { group in
                    for await update in transcriber.updates {
                        switch update {
                        case .volatile(let text):
                            overlay.showVolatile(text, speaker: speaker)
                        case .final(let text, let start, let end):
                            let segment = Segment(id: UUID(), speaker: speaker, start: start, end: end, text: text)
                            let arrived = Date()
                            if speaker == .remote {
                                self?.recentRemote.removeAll { arrived.timeIntervalSince($0.at) > 15 }
                                self?.recentRemote.append((text, arrived))
                                await commit(segment)
                                continue
                            }
                            // me는 2초 보류: 그 사이 도착한 remote와 [-6s,+2s] 안에서 비슷하면 에코로 버린다.
                            // 보류는 별도 Task라 다음 me 미리보기를 막지 않는다.
                            group.addTask { @MainActor in
                                try? await Task.sleep(for: .seconds(2))
                                let isEcho = self?.recentRemote.contains {
                                    $0.at.timeIntervalSince(arrived) >= -6 && $0.at.timeIntervalSince(arrived) <= 2
                                        && EchoDedup.isEcho(me: text, remote: $0.text)
                                } ?? false
                                if !isEcho { await commit(segment) }
                            }
                        }
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
        remoteRecorder?.close()
        remoteRecorder = nil
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
        // 오디오/STT는 모두 해제됐으니 바로 새 미팅을 시작할 수 있다.
        state = .idle
        enqueueNotes(folder: store.folder, diarize: true)
    }

    func regenerateNotes(_ record: MeetingRecord) {
        enqueueNotes(folder: record.folder, diarize: false)
    }

    /// 노트 작업을 큐에 넣는다. 이미 대기/진행 중인 폴더는 무시.
    /// 메모리: 노트 생성 중 새 미팅을 시작하면 STT + LLM(12B)이 함께 올라간다(~9GB). 감수한다.
    private func enqueueNotes(folder: URL, diarize: Bool) {
        guard notesJob != folder, !pendingNotes.contains(where: { $0.folder == folder }) else { return }
        pendingNotes.append((folder, diarize))
        if notesWorker == nil {
            notesWorker = Task {
                while !pendingNotes.isEmpty {
                    let job = pendingNotes.removeFirst()
                    notesJob = job.folder
                    notesTitle = TranscriptStore.readMeta(in: job.folder)?.title ?? ""
                    if job.diarize {
                        // 화자 구분을 먼저 끝내야 노트에 "상대 1/2"가 들어간다. 실패해도 노트는 만든다.
                        notesProgress = "화자 구분 중…"
                        do { _ = try await Diarizer.labelSpeakers(folder: job.folder) } catch { print("diarization failed:", error) }
                    }
                    await generateNotes(folder: job.folder)
                }
                notesWorker = nil
            }
        }
    }

    private func generateNotes(folder: URL) async {
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
        notesJob = nil
        refreshUnfinishedMeetings()
    }

    /// 메뉴에 보일 한 줄. 작업이 없으면 nil.
    var notesStatus: String? {
        guard notesJob != nil else { return nil }
        let queued = pendingNotes.isEmpty ? "" : " (대기 \(pendingNotes.count))"
        return "노트 생성 중: \(notesTitle) – \(notesProgress ?? "준비 중…")\(queued)"
    }

    private func captureFailed(_ error: Error) async {
        await stop()
        errorMessage = "캡처가 중단됐습니다: \(error.localizedDescription)"
    }
}
