import AVFoundation
import CoreGraphics
import Observation

/// 한 미팅의 생명주기. M2: 상대(시스템 오디오) 자막 + 한국어 번역.
@MainActor @Observable
final class SessionController {
    enum State { case idle, starting, recording }

    private(set) var state = State.idle
    private(set) var errorMessage: String?
    /// 한국어 번역 언어팩이 없으면 자막만 띄우고 메뉴에서 설치를 안내한다.
    private(set) var translationMissing = false
    var overlay = OverlayController()

    @ObservationIgnored private var capture: AudioCapture?
    @ObservationIgnored private var transcriber: Transcriber?
    @ObservationIgnored private var updatesTask: Task<Void, Never>?
    @ObservationIgnored private var translationTask: Task<Void, Never>?

    init() {
        // 마이크는 M3에서 쓰지만 권한은 미리 받아 둔다.
        AVCaptureDevice.requestAccess(for: .audio) { _ in }
        Task { await refreshTranslationAvailability() }
    }

    func refreshTranslationAvailability() async {
        translationMissing = !(await AppleTranslator.isInstalled())
    }

    func start() async {
        guard state == .idle else { return }
        errorMessage = nil
        guard CGPreflightScreenCaptureAccess() else {
            CGRequestScreenCaptureAccess()
            errorMessage = "시스템 설정 > 개인정보 보호 > 화면 및 시스템 오디오 녹화에서 Roomline을 허용한 뒤 앱을 다시 실행하세요."
            return
        }
        state = .starting
        overlay.clear()

        let transcriber = AppleTranscriber()
        do {
            let format = try await transcriber.prepare()
            let capture = AudioCapture(
                targetFormat: format,
                onRemote: { transcriber.append($0) },
                onError: { error in Task { @MainActor [weak self] in await self?.fail(error) } })
            try await capture.start()
            self.transcriber = transcriber
            self.capture = capture
        } catch {
            await transcriber.finish()
            state = .idle
            errorMessage = error.localizedDescription
            return
        }

        await refreshTranslationAvailability()
        let (finals, finalsContinuation) = AsyncStream<(CaptionLine.ID, String)>.makeStream()
        if !translationMissing {
            let translator: Translator = AppleTranslator()
            // 한 루프에서 하나씩 처리해 도착 순서대로 번역이 붙는다.
            translationTask = Task { [overlay] in
                for await (id, text) in finals {
                    do {
                        overlay.setTranslation(try await translator.translate(text), for: id)
                    } catch {
                        print("translation failed:", error)
                    }
                }
            }
        }

        updatesTask = Task { [overlay] in
            for await update in transcriber.updates {
                switch update {
                case .volatile(let text):
                    overlay.showVolatile(text)
                case .final(let text, _, _):
                    let id = overlay.appendFinal(text, speaker: .remote)
                    finalsContinuation.yield((id, text))
                }
            }
            finalsContinuation.finish()
        }
        state = .recording
    }

    func stop() async {
        guard state == .recording else { return }
        await capture?.stop()
        await transcriber?.finish()
        await updatesTask?.value
        await translationTask?.value
        capture = nil
        transcriber = nil
        updatesTask = nil
        translationTask = nil
        state = .idle
    }

    private func fail(_ error: Error) async {
        await stop()
        errorMessage = "캡처가 중단됐습니다: \(error.localizedDescription)"
    }
}
