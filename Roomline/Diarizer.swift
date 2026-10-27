import AVFoundation
import FluidAudio
import Foundation

/// 미팅 후 상대 채널(remote.caf 또는 압축된 remote.m4a)을 화자 구분해 세그먼트마다 speakerLabel 이벤트를 덧붙인다.
/// 끝나면 caf를 m4a로 압축하고, 저장된 목소리 프로필과 맞는 화자에 이름을 미리 채운다.
enum Diarizer {
    enum Failure: LocalizedError {
        case noAudio
        var errorDescription: String? { "상대 음성 녹음이 없어 화자를 구분할 수 없습니다." }
    }

    /// 구분된 화자 수를 돌려준다. 모델은 첫 실행 때 내려받는다.
    static func labelSpeakers(folder: URL) async throws -> Int {
        let caf = folder.appending(path: RemoteAudioRecorder.fileName)
        let m4a = folder.appending(path: "remote.m4a")
        let fm = FileManager.default
        guard let audio = [caf, m4a].first(where: { fm.fileExists(atPath: $0.path) }) else { throw Failure.noAudio }

        let manager = OfflineDiarizerManager()
        try await manager.prepareModels()
        let result = try await manager.process(audio)
        let spans = result.segments

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

        // 화자별 중심 임베딩 저장 + 알려진 목소리면 이름 미리 채우기(사용자가 이미 정한 번호는 유지)
        var centroids: [Int: [Float]] = [:]
        for (id, embedding) in result.speakerDatabase ?? [:] { if let n = numbers[id] { centroids[n] = VoiceProfiles.normalized(embedding) } }
        if !centroids.isEmpty {
            try? VoiceProfiles.saveCentroids(centroids, to: folder)
            if var meta = TranscriptStore.readMeta(in: folder) {
                var names = meta.speakerNames ?? [:]
                let taken = Set(names.values)
                for m in VoiceProfiles.match(centroids.filter { names[$0.key] == nil }, profiles: VoiceProfiles.load().filter { !taken.contains($0.name) }) {
                    names[m.speaker] = m.name
                }
                meta.speakerNames = names.isEmpty ? nil : names
                try? TranscriptStore.write(meta, to: folder)
            }
        }

        if audio == caf, (try? compress(caf, to: m4a)) != nil { try? fm.removeItem(at: caf) }
        return numbers.count
    }

    /// caf → AAC m4a(16 kHz 모노 32 kbps). 결과 파일이 비어 있으면 실패로 본다.
    private static func compress(_ source: URL, to dest: URL) throws {
        try write(source, to: dest)   // AVAudioFile은 해제될 때 마무리되므로 함수를 빠져나온 뒤 크기를 확인한다.
        let size = (try? FileManager.default.attributesOfItem(atPath: dest.path)[.size] as? Int) ?? 0
        guard size > 0 else { throw Failure.noAudio }
    }

    private static func write(_ source: URL, to dest: URL) throws {
        let input = try AVAudioFile(forReading: source)
        let output = try AVAudioFile(forWriting: dest, settings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 16000, AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 32000,
        ])
        guard let buffer = AVAudioPCMBuffer(pcmFormat: input.processingFormat, frameCapacity: 16000 * 10) else { return }
        while input.framePosition < input.length {
            try input.read(into: buffer)
            try output.write(from: buffer)
        }
    }
}
