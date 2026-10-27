import FluidAudio
import Foundation

/// 미팅 후 상대 채널(remote.caf)을 화자 구분해 세그먼트마다 speakerLabel 이벤트를 덧붙인다.
enum Diarizer {
    enum Failure: LocalizedError {
        case noAudio
        var errorDescription: String? { "상대 음성 녹음(remote.caf)이 없어 화자를 구분할 수 없습니다." }
    }

    /// 구분된 화자 수를 돌려준다. 모델은 첫 실행 때 내려받는다.
    static func labelSpeakers(folder: URL) async throws -> Int {
        let audio = folder.appending(path: RemoteAudioRecorder.fileName)
        guard FileManager.default.fileExists(atPath: audio.path) else { throw Failure.noAudio }

        let manager = OfflineDiarizerManager()
        try await manager.prepareModels()
        let spans = try await manager.process(audio).segments

        // FluidAudio 화자 id → 처음 등장한 순서의 1부터 시작하는 번호
        var numbers: [String: Int] = [:]
        for span in spans.sorted(by: { $0.startTimeSeconds < $1.startTimeSeconds }) where numbers[span.speakerId] == nil {
            numbers[span.speakerId] = numbers.count + 1
        }

        var events: [TranscriptEvent] = []
        for line in TranscriptStore.loadTranscript(in: folder) where line.segment.speaker == .remote {
            // 겹치는 시간이 가장 긴 화자
            var overlap: [Int: Double] = [:]
            for span in spans {
                let t = min(line.segment.end, Double(span.endTimeSeconds)) - max(line.segment.start, Double(span.startTimeSeconds))
                if t > 0 { overlap[numbers[span.speakerId]!, default: 0] += t }
            }
            if let best = overlap.max(by: { $0.value < $1.value }) {
                events.append(.speakerLabel(segmentID: line.segment.id, speaker: best.key))
            }
        }
        try TranscriptStore.append(events, to: folder)
        return numbers.count
    }
}
