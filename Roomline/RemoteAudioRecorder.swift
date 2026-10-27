import AVFoundation

/// 상대 채널 오디오를 remote.caf로 저장한다(미팅 후 화자 구분용).
/// Int16 PCM CAF는 용량이 시간당 ~115MB로 크지만 쓰다가 죽어도 헤더가 복구돼 재생·분석이 되므로 AAC 대신 선택.
final class RemoteAudioRecorder {
    static let fileName = "remote.caf"
    private var file: AVAudioFile?

    init(folder: URL, format: AVAudioFormat) throws {
        file = try AVAudioFile(forWriting: folder.appending(path: Self.fileName), settings: format.settings,
                               commonFormat: format.commonFormat, interleaved: format.isInterleaved)
    }

    /// 캡처 큐 하나에서만 호출한다.
    func append(_ buffer: AVAudioPCMBuffer) {
        do { try file?.write(from: buffer) } catch { print("remote audio write failed:", error) }
    }

    func close() { file = nil }
}
