import AVFoundation
import Foundation

// AudioCapture.swift가 요구하는 타입 (Models.swift 대신 최소 스텁)

/// 소문자, 구두점 제거, 공백 정리.
func normalizeWords(_ s: String) -> [String] {
    s.lowercased().map { $0.isLetter || $0.isNumber || $0 == " " || $0 == "\n" || $0 == "'" ? $0 : " " }
        .split(whereSeparator: { $0 == " " || $0 == "\n" }).map { String($0).replacingOccurrences(of: "'", with: "") }
}

/// 단어 단위 Levenshtein / 참조 단어 수.
func wer(reference: String, hypothesis: String) -> Double {
    let r = normalizeWords(reference), h = normalizeWords(hypothesis)
    if r.isEmpty { return h.isEmpty ? 0 : 1 }
    var prev = Array(0...h.count)
    for i in 1...r.count {
        var cur = [i] + Array(repeating: 0, count: h.count)
        for j in 1...max(h.count, 1) where !h.isEmpty {
            cur[j] = min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (r[i - 1] == h[j - 1] ? 0 : 1))
        }
        prev = cur
    }
    return Double(prev[h.count]) / Double(r.count)
}

func selfcheck() {
    assert(wer(reference: "the cat sat", hypothesis: "The cat sat.") == 0)
    assert(abs(wer(reference: "the cat sat on the mat", hypothesis: "the bat sat the mat") - 2.0 / 6) < 1e-9)  // 치환1+삭제1
    assert(wer(reference: "a b", hypothesis: "") == 1)
    print("bench selfcheck ok")
}

func run(file: URL, locale: String) async throws -> (text: String, wall: Double) {
    let transcriber = AppleTranscriber(locale: Locale(identifier: locale))
    let format = try await transcriber.prepare()
    let collector = Task {
        var parts: [String] = []
        for await u in transcriber.updates { if case .final(let t, _, _) = u { parts.append(t) } }
        return parts
    }
    let started = Date()
    let audio = try AVAudioFile(forReading: file)
    let converter = ChannelConverter(target: format)
    while audio.framePosition < audio.length {
        guard let buf = AVAudioPCMBuffer(pcmFormat: audio.processingFormat, frameCapacity: 8192) else { break }
        try audio.read(into: buf)
        if buf.frameLength == 0 { break }
        if let out = converter.convert(buf) { transcriber.append(out) }
    }
    await transcriber.finish()
    let parts = await collector.value
    return (parts.joined(separator: " "), Date().timeIntervalSince(started))
}

@main
struct Bench {
    static func main() async {
        let args = Array(CommandLine.arguments.dropFirst())
        if args.first == "--selfcheck" { return selfcheck() }
        guard args.count >= 2 else { print("usage: bench.sh <audio> <reference.txt> [locales...]"); exit(1) }
        let file = URL(fileURLWithPath: args[0])
        let reference = (try? String(contentsOfFile: args[1], encoding: .utf8)) ?? ""
        let locales = args.count > 2 ? Array(args[2...]) : ["en_US", "en_IN", "en_GB"]
        let duration = (try? AVAudioFile(forReading: file)).map { Double($0.length) / $0.processingFormat.sampleRate } ?? 0
        print("audio \(String(format: "%.1f", duration))s, reference \(normalizeWords(reference).count) words")
        print("locale   WER     words  wall(s)  RTF")
        for l in locales {
            do {
                let r = try await run(file: file, locale: l.replacingOccurrences(of: "_", with: "-"))
                try r.text.write(toFile: args[0] + ".\(l).txt", atomically: true, encoding: .utf8)
                print(String(format: "%@  %5.1f%%  %5d  %7.1f  %.3f", l.padding(toLength: 7, withPad: " ", startingAt: 0),
                             wer(reference: reference, hypothesis: r.text) * 100, normalizeWords(r.text).count, r.wall, duration > 0 ? r.wall / duration : 0))
            } catch {
                print("\(l)  failed: \(error)")
            }
        }
    }
}
