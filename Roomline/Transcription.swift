import AVFoundation
import Speech

enum TranscriptUpdate: Sendable {
    case volatile(String)
    /// start/end: 이 채널 오디오 시작 기준 초
    case final(text: String, start: TimeInterval, end: TimeInterval)
}

/// WhisperKit 등으로 교체할 수 있게 둔 경계.
protocol Transcriber: AnyObject, Sendable {
    /// 모델을 준비하고, append로 넣어줄 오디오 포맷을 돌려준다.
    func prepare() async throws -> AVAudioFormat
    var updates: AsyncStream<TranscriptUpdate> { get }
    /// prepare가 돌려준 포맷의 버퍼. 아무 스레드에서나 호출 가능.
    func append(_ buffer: AVAudioPCMBuffer)
    func finish() async
}

enum TranscriptionError: LocalizedError {
    case localeUnsupported, noAudioFormat

    var errorDescription: String? {
        switch self {
        case .localeUnsupported: "이 Mac에서 선택한 영어 억양의 음성 인식을 지원하지 않습니다."
        case .noAudioFormat: "음성 인식 오디오 포맷을 정하지 못했습니다."
        }
    }
}

/// SpeechAnalyzer + SpeechTranscriber. 채널 하나당 하나씩 만든다.
final class AppleTranscriber: Transcriber, @unchecked Sendable {
    let updates: AsyncStream<TranscriptUpdate>
    private let updatesContinuation: AsyncStream<TranscriptUpdate>.Continuation
    private let input: AsyncStream<AnalyzerInput>
    private let inputContinuation: AsyncStream<AnalyzerInput>.Continuation
    private var analyzer: SpeechAnalyzer?
    private var resultsTask: Task<Void, Never>?

    private let locale: Locale

    init(locale: Locale = Locale(identifier: "en-US")) {
        self.locale = locale
        (updates, updatesContinuation) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(64))
        (input, inputContinuation) = AsyncStream.makeStream()  // 버리면 오디오 타임라인이 어긋나므로 무제한
    }

    func prepare() async throws -> AVAudioFormat {
        let requested = locale
        guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: requested) else {
            throw TranscriptionError.localeUnsupported
        }
        let transcriber = SpeechTranscriber(
            locale: locale,
            transcriptionOptions: [],
            reportingOptions: [.volatileResults, .fastResults],
            attributeOptions: [.audioTimeRange])

        // 최초 실행 때만 실제 다운로드가 일어난다.
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            try await request.downloadAndInstall()
        }
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
            throw TranscriptionError.noAudioFormat
        }

        let analyzer = SpeechAnalyzer(modules: [transcriber])
        try await analyzer.prepareToAnalyze(in: format)
        try await analyzer.start(inputSequence: input)
        self.analyzer = analyzer

        let continuation = updatesContinuation
        resultsTask = Task {
            do {
                for try await result in transcriber.results {
                    let text = String(result.text.characters).trimmingCharacters(in: .whitespacesAndNewlines)
                    if result.isFinal {
                        guard !text.isEmpty else { continue }
                        continuation.yield(.final(
                            text: text,
                            start: result.range.start.seconds,
                            end: result.range.end.seconds))
                    } else {
                        continuation.yield(.volatile(text))
                    }
                }
            } catch {
                print("transcriber results ended:", error)
            }
            continuation.finish()
        }
        return format
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        inputContinuation.yield(AnalyzerInput(buffer: buffer))
    }

    func finish() async {
        inputContinuation.finish()
        try? await analyzer?.finalizeAndFinishThroughEndOfInput()
        await resultsTask?.value
        analyzer = nil
    }
}
