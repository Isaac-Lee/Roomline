import AVFoundation
import ScreenCaptureKit

enum CaptureError: LocalizedError {
    case noDisplay

    var errorDescription: String? { "캡처할 디스플레이를 찾지 못했습니다." }
}

/// SCStream 하나로 시스템 오디오를 받아 음성 인식 포맷으로 변환해 넘긴다.
/// 디스플레이 필터가 필수라 비디오는 2x2 / 1fps로 받고 버린다.
final class AudioCapture: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    private let queue = DispatchQueue(label: "roomline.audio-capture")
    private let remote: ChannelConverter
    private let onRemote: @Sendable (AVAudioPCMBuffer) -> Void
    private let onError: @Sendable (Error) -> Void
    private var stream: SCStream?

    init(
        targetFormat: AVAudioFormat,
        onRemote: @escaping @Sendable (AVAudioPCMBuffer) -> Void,
        onError: @escaping @Sendable (Error) -> Void
    ) {
        remote = ChannelConverter(target: targetFormat)
        self.onRemote = onRemote
        self.onError = onError
    }

    func start() async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first else { throw CaptureError.noDisplay }
        let filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])

        let config = SCStreamConfiguration()
        config.width = 2
        config.height = 2
        config.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        config.queueDepth = 1
        config.capturesAudio = true
        config.excludesCurrentProcessAudio = true
        config.sampleRate = 48_000
        config.channelCount = 1

        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        // .screen 출력을 안 붙이면 프레임마다 에러 로그가 찍혀서 받아서 버린다.
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue)
        try await stream.startCapture()
        self.stream = stream
    }

    func stop() async {
        try? await stream?.stopCapture()
        stream = nil
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio, sampleBuffer.isValid,
              let pcm = sampleBuffer.pcmBuffer(),
              let converted = remote.convert(pcm) else { return }
        onRemote(converted)
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        onError(error)
    }
}

/// 채널 하나의 포맷 변환. 채널마다 클록·샘플레이트가 달라 따로 둔다.
final class ChannelConverter {
    private let target: AVAudioFormat
    private var converter: AVAudioConverter?

    init(target: AVAudioFormat) {
        self.target = target
    }

    func convert(_ input: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        if converter?.inputFormat != input.format {
            converter = AVAudioConverter(from: input.format, to: target)
        }
        guard let converter else { return nil }

        let ratio = target.sampleRate / input.format.sampleRate
        let capacity = AVAudioFrameCount((Double(input.frameLength) * ratio).rounded(.up)) + 32
        guard let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return nil }

        var consumed = false
        var error: NSError?
        converter.convert(to: output, error: &error) { _, status in
            if consumed {
                status.pointee = .noDataNow
                return nil
            }
            consumed = true
            status.pointee = .haveData
            return input
        }
        if let error {
            print("audio convert failed:", error)
            return nil
        }
        return output.frameLength > 0 ? output : nil
    }
}

extension CMSampleBuffer {
    func pcmBuffer() -> AVAudioPCMBuffer? {
        guard var asbd = formatDescription?.audioStreamBasicDescription,
              let format = AVAudioFormat(streamDescription: &asbd) else { return nil }
        let frames = AVAudioFrameCount(numSamples)
        guard frames > 0, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { return nil }
        buffer.frameLength = frames
        let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(
            self, at: 0, frameCount: Int32(frames), into: buffer.mutableAudioBufferList)
        return status == noErr ? buffer : nil
    }
}
