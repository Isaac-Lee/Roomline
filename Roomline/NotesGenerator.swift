import Foundation

enum NotesError: LocalizedError {
    case emptyTranscript
    case ollamaUnavailable
    case ollama(String)

    var errorDescription: String? {
        switch self {
        case .emptyTranscript: "전사 내용이 없습니다."
        case .ollamaUnavailable: "Ollama에 연결할 수 없습니다. `ollama serve`가 실행 중인지 확인하세요 (localhost:11434)."
        case .ollama(let message): "Ollama 오류: \(message)"
        }
    }
}

/// 미팅 후에만 실행. 전사를 ~10분 구간으로 잘라 요약(map)한 뒤 합쳐서(reduce) 한국어 노트를 만든다.
struct NotesGenerator {
    static let chunkDuration: TimeInterval = 600
    static let endpoint = URL(string: "http://localhost:11434/api/chat")!

    let model: String

    func generate(
        meta: MeetingMeta,
        lines: [TranscriptLine],
        progress: @MainActor (String) -> Void
    ) async throws -> String {
        let lines = Self.condense(lines)
        guard !lines.isEmpty else { throw NotesError.emptyTranscript }
        let chunks = Self.chunks(lines)

        let material: String
        if chunks.count == 1 {
            material = Self.format(chunks[0])
        } else {
            var summaries: [String] = []
            for (index, chunk) in chunks.enumerated() {
                await progress("구간 요약 \(index + 1)/\(chunks.count)…")
                let range = "\(Self.clock(chunk.first!.segment.start))~\(Self.clock(chunk.last!.segment.end))"
                let summary = try await chat(system: Self.mapPrompt, user: "[\(range)]\n\(Self.format(chunk))", unload: false, maxTokens: 500)
                summaries.append("### \(range)\n\(summary)")
            }
            material = summaries.joined(separator: "\n\n")
        }

        await progress("최종 노트 작성 중…")
        // 마지막 호출에서 keep_alive 0으로 모델을 내린다.
        let body = try await chat(system: Self.reducePrompt, user: material, unload: true, maxTokens: 1500)

        let date = meta.startedAt.formatted(date: .long, time: .shortened)
        let duration = Int((meta.endedAt ?? meta.startedAt).timeIntervalSince(meta.startedAt) / 60)
        return "# \(meta.title)\n\n- 일시: \(date) (\(duration)분)\n- 모델: \(model)\n\n\(body)\n"
    }

    // MARK: 전사 가공

    private static let fillers: Set<String> = ["uh", "um", "uhm", "hmm", "mm", "ah", "er", "음", "어"]

    /// 정보량 낮은 줄(필러 제외 3단어 미만, 숫자 없음)을 버리고, 같은 화자의 연속 줄은 한 줄로 합친다.
    static func condense(_ lines: [TranscriptLine]) -> [TranscriptLine] {
        var out: [TranscriptLine] = []
        for line in lines {
            let text = line.segment.text
            let words = text.split { !$0.isLetter && !$0.isNumber && $0 != "'" }.filter { !fillers.contains($0.lowercased()) }
            guard words.count >= 3 || text.contains(where: \.isNumber) else { continue }
            if var last = out.last, last.speakerName == line.speakerName {
                let s = last.segment
                last = TranscriptLine(segment: Segment(id: s.id, speaker: s.speaker, start: s.start, end: line.segment.end, text: s.text + " " + text),
                                      remoteSpeaker: last.remoteSpeaker, remoteSpeakerName: last.remoteSpeakerName)
                out[out.count - 1] = last
            } else {
                out.append(line)
            }
        }
        return out
    }

    static func chunks(_ lines: [TranscriptLine]) -> [[TranscriptLine]] {
        Dictionary(grouping: lines) { Int($0.segment.start / chunkDuration) }
            .sorted { $0.key < $1.key }
            .map(\.value)
    }

    static func format(_ lines: [TranscriptLine]) -> String {
        lines.map { line in
            "[\(clock(line.segment.start))] \(line.speakerName): \(line.segment.text)"
        }
        .joined(separator: "\n")
    }

    static func clock(_ seconds: TimeInterval) -> String {
        let s = Int(seconds)
        return String(format: "%02d:%02d", s / 60, s % 60)
    }

    // MARK: Ollama

    private struct ChatResponse: Decodable {
        struct Message: Decodable { let content: String }
        let message: Message?
        let error: String?
    }

    private func chat(system: String, user: String, unload: Bool, maxTokens: Int) async throws -> String {
        var request = URLRequest(url: Self.endpoint, timeoutInterval: 600)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        var body: [String: Any] = [
            "model": model,
            "stream": false,
            "think": false,   // 추론형 모델(qwen3 등)의 사고 단계를 끈다. 미지원 모델은 무시.
            "messages": [
                ["role": "system", "content": system],
                ["role": "user", "content": user],
            ],
            // num_predict: 장황한 출력이 시간을 다 잡아먹는 것을 막는다.
            "options": ["temperature": 0.2, "num_ctx": 8192, "num_predict": maxTokens],
        ]
        if unload { body["keep_alive"] = 0 }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let data: Data
        do {
            (data, _) = try await URLSession.shared.data(for: request)
        } catch let error as URLError where error.code == .cannotConnectToHost || error.code == .cannotFindHost {
            throw NotesError.ollamaUnavailable
        }
        let response = try JSONDecoder().decode(ChatResponse.self, from: data)
        if let error = response.error { throw NotesError.ollama(error) }
        return Self.stripThinking(response.message?.content ?? "")
    }

    /// 추론형 모델이 내놓는 <think>…</think>를 떼어 낸다.
    static func stripThinking(_ text: String) -> String {
        guard let end = text.range(of: "</think>") else { return text.trimmingCharacters(in: .whitespacesAndNewlines) }
        return String(text[end.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: 프롬프트

    static let mapPrompt = """
    너는 회의록 작성자다. 사용자가 영어 또는 한국어 회의 전사의 한 구간을 준다. "나"는 노트 주인이고, 그 밖의 화자 이름("상대", "상대 2", 실제 이름)은 상대방이다.
    이 구간에서 구체적으로 합의·결정된 것과 담당자·기한이 있는 할 일만 한국어 bullet로 정리해라. 잡담·반복·추측은 버리고, 전사에 없는 내용은 절대 지어내지 마라.
    형식(해당 없는 항목은 생략, 전체 15줄 이내, 한 줄은 짧게):
    - 논의: 핵심 주제 1~3줄
    - 결정: …
    - 액션: 나 — …(기한)
    - 미해결: …
    액션의 담당자는 "나", 전사에 나온 실제 이름, 모르면 "상대" 중 하나다. 예시 줄을 그대로 베끼지 마라.
    """

    static let reducePrompt = """
    너는 회의록 작성자다. 사용자가 영어 또는 한국어 회의 전사, 혹은 구간별 요약을 준다. "나"는 노트 주인이고, 그 밖의 화자 이름("상대", "상대 2", 실제 이름)은 상대방이다.
    전체를 하나로 합쳐 아래 형식의 한국어 Markdown 미팅 노트만 출력해라. 구간별로 나누지 말고, 같은 내용은 하나로 합치고, 전사에 없는 내용은 지어내지 마라.
    잡담성 반복은 버리고 결정·할 일·미해결만 남긴다. 고유명사·제품명·숫자·날짜는 원문 그대로 둔다. 액션아이템은 명시적으로 맡은 일만 쓰고(최대 10개, 같은 일은 하나로), 담당자는 전사·요약에 나온 실제 이름으로 쓴다. 노트 주인이면 "나"(예시 줄의 "나"도 이 규칙대로 실제 이름으로 바꾼다). 담당자가 불분명한 일은 액션아이템에 넣지 말고 미해결에 둔다.

    ## 요약
    3~6줄 문단

    ## 결정사항
    - …

    ## 액션아이템
    - [ ] 나: …(기한)

    ## 미해결 논의
    - …

    해당 내용이 없는 섹션은 "- 없음"이라고 써라.
    """
}
