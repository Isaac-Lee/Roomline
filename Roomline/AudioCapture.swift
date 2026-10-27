import AVFoundation
import CoreAudio
import ScreenCaptureKit

enum CaptureError: LocalizedError {
    case noDisplay

    var errorDescription: String? { "캡처할 디스플레이를 찾지 못했습니다." }
}

/// SCStream 하나로 시스템 오디오(상대)와 마이크(나)를 받아 채널별로 음성 인식 포맷으로 변환해 넘긴다.
/// 디스플레이 필터가 필수라 비디오는 2x2 / 1fps로 받고 버린다.
final class AudioCapture: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    /// 시스템 오디오가 이 RMS보다 크면 "상대가 말하는 중"으로 본다. (-40 dBFS)
    /// ponytail: 고정 임계값, 스피커 볼륨·환경에 따라 조정이 필요하면 설정으로 뺀다.
    static let echoGateThreshold: Float = 0.01
    /// 상대 소리가 그친 뒤에도 잔향을 막으려고 마이크를 조금 더 막아 둔다.
    static let echoGateHold: TimeInterval = 0.3

    private let queue = DispatchQueue(label: "roomline.audio-capture")
    private let remote: ChannelConverter
    private let me: ChannelConverter
    private let echoGate: Bool
    private let onBuffer: @Sendable (Speaker, AVAudioPCMBuffer) -> Void
    private let onError: @Sendable (Error) -> Void
    private var stream: SCStream?
    private var config: SCStreamConfiguration?
    private var remoteLoudUntil = Date.distantPast   // queue에서만 접근
    private var deviceListener: AudioObjectPropertyListenerBlock?

    init(
        targetFormat: AVAudioFormat,
        echoGate: Bool,
        onBuffer: @escaping @Sendable (Speaker, AVAudioPCMBuffer) -> Void,
        onError: @escaping @Sendable (Error) -> Void
    ) {
        remote = ChannelConverter(target: targetFormat)
        me = ChannelConverter(target: targetFormat)
        self.echoGate = echoGate
        self.onBuffer = onBuffer
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
        config.captureMicrophone = true
        config.microphoneCaptureDeviceID = AVCaptureDevice.default(for: .audio)?.uniqueID

        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        // .screen 출력을 안 붙이면 프레임마다 에러 로그가 찍혀서 받아서 버린다.
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue)
        try stream.addStreamOutput(self, type: .microphone, sampleHandlerQueue: queue)
        try await stream.startCapture()
        self.stream = stream
        self.config = config
        observeDefaultInputDevice()
    }

    func stop() async {
        removeDeviceListener()
        try? await stream?.stopCapture()
        stream = nil
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type != .screen, sampleBuffer.isValid, let pcm = sampleBuffer.pcmBuffer() else { return }
        switch type {
        case .audio:
            if echoGate, pcm.rms() > Self.echoGateThreshold {
                remoteLoudUntil = Date(timeIntervalSinceNow: Self.echoGateHold)
            }
            if let converted = remote.convert(pcm) { onBuffer(.remote, converted) }
        case .microphone:
            guard let converted = me.convert(pcm) else { return }
            // 버퍼를 버리면 타임라인이 어긋나므로 무음으로 바꿔서 넘긴다.
            if echoGate, Date() < remoteLoudUntil { converted.silence() }
            onBuffer(.me, converted)
        default:
            break
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        onError(error)
    }

    // MARK: 마이크 장치 변경 (에어팟 연결·해제)

    private func observeDefaultInputDevice() {
        var address = Self.defaultInputAddress
        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            Task { await self?.switchToDefaultMicrophone() }
        }
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, queue, listener)
        deviceListener = listener
    }

    private func removeDeviceListener() {
        guard let listener = deviceListener else { return }
        var address = Self.defaultInputAddress
        AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, queue, listener)
        deviceListener = nil
    }

    /// 스트림을 다시 만들지 않고 설정만 바꾼다. 새 장치 포맷은 ChannelConverter가 알아서 따라간다.
    /// ponytail: 전환 중 끊긴 구간만큼 "나" 채널 타임스탬프가 뒤로 밀린다. 문제 되면 bufferStartTime을 넘긴다.
    private func switchToDefaultMicrophone() async {
        guard let stream, let config,
              let deviceID = AVCaptureDevice.default(for: .audio)?.uniqueID,
              deviceID != config.microphoneCaptureDeviceID else { return }
        config.microphoneCaptureDeviceID = deviceID
        do {
            try await stream.updateConfiguration(config)
            print("microphone switched to", deviceID)
        } catch {
            print("microphone switch failed:", error)
        }
    }

    private static let defaultInputAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultInputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain)
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

extension AVAudioPCMBuffer {
    /// 첫 채널의 RMS. SCK 시스템 오디오는 Float32라 그 외 포맷은 0으로 본다.
    func rms() -> Float {
        guard let samples = floatChannelData?[0], frameLength > 0 else { return 0 }
        var sum: Float = 0
        for i in 0..<Int(frameLength) { sum += samples[i] * samples[i] }
        return (sum / Float(frameLength)).squareRoot()
    }

    func silence() {
        let buffers = UnsafeMutableAudioBufferListPointer(mutableAudioBufferList)
        for buffer in buffers {
            if let data = buffer.mData { memset(data, 0, Int(buffer.mDataByteSize)) }
        }
    }
}
