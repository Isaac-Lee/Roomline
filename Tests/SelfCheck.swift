// 실행: Tests/selfcheck.sh
// 저장 포맷(append-only JSONL 재생)과 노트용 전사 가공을 확인한다.
import Foundation

@main
struct SelfCheck {
    static func main() async throws {
        // 1. 세그먼트 → 번역(순서 뒤바뀜) → 죽는 순간의 깨진 줄 → 다시 읽기
        let store = try TranscriptStore()
        let a = Segment(id: UUID(), speaker: .remote, start: 5, end: 7, text: "Hello there.")
        let b = Segment(id: UUID(), speaker: .me, start: 1, end: 3, text: "Hi.")
        await store.append(.segment(a))
        await store.append(.segment(b))
        await store.append(.translation(segmentID: a.id, text: "안녕하세요."))
        let handle = try FileHandle(forWritingTo: store.folder.appending(path: "transcript.jsonl"))
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("{\"segment\":{\"_0\":{\"id\"".utf8))
        try handle.close()
        await store.update { $0.state = .done }

        let lines = TranscriptStore.loadTranscript(in: store.folder)
        assert(lines.map(\.segment.text) == ["Hi.", "Hello there."], "시간순 정렬")
        assert(lines[1].translation == "안녕하세요." && lines[0].translation == nil, "번역 병합")
        let id = await store.meta.id
        assert(TranscriptStore.list().contains { $0.id == id && $0.meta.state == .done }, "meta 목록")
        try FileManager.default.removeItem(at: store.folder)

        // 1b. 화자 라벨 병합(마지막 라벨 우선), 라벨 없는 줄·내 발화 이름
        let store2 = try TranscriptStore()
        let r1 = Segment(id: UUID(), speaker: .remote, start: 0, end: 2, text: "A")
        let r2 = Segment(id: UUID(), speaker: .remote, start: 3, end: 5, text: "B")
        let m = Segment(id: UUID(), speaker: .me, start: 6, end: 7, text: "C")
        for s in [r1, r2, m] { await store2.append(.segment(s)) }
        try TranscriptStore.append([.speakerLabel(segmentID: r1.id, speaker: 1), .speakerLabel(segmentID: r2.id, speaker: 1),
                                    .speakerLabel(segmentID: r2.id, speaker: 2)], to: store2.folder)
        let labeled = TranscriptStore.loadTranscript(in: store2.folder)
        assert(labeled.map(\.speakerName) == ["상대 1", "상대 2", "나"], "화자 이름 \(labeled.map(\.speakerName))")
        assert(TranscriptLine(segment: r1).speakerName == "상대")
        var named = await store2.meta
        named.speakerNames = [2: "Dana"]
        try TranscriptStore.write(named, to: store2.folder)
        assert(TranscriptStore.loadTranscript(in: store2.folder).map(\.speakerName) == ["상대 1", "Dana", "나"], "지정한 화자 이름")
        let old = #"{"id":"\#(UUID().uuidString)","title":"t","startedAt":"2026-01-01T00:00:00Z","state":"done"}"#
        assert((try? JSONDecoder.iso.decode(MeetingMeta.self, from: Data(old.utf8)))?.speakerNames == nil, "옛 meta 호환")
        try FileManager.default.removeItem(at: store2.folder)

        // 2. 10분 단위 구간 나누기
        let long = (0..<25).map { i in
            TranscriptLine(segment: Segment(id: UUID(), speaker: .remote, start: Double(i * 60), end: Double(i * 60 + 5), text: "s\(i)"))
        }
        let chunks = NotesGenerator.chunks(long)
        assert(chunks.map(\.count) == [10, 10, 5], "구간 크기 \(chunks.map(\.count))")
        assert(NotesGenerator.format([long[11]]) == "[11:00] 상대: s11")
        assert(NotesGenerator.stripThinking("<think>hmm</think>\n## 요약") == "## 요약")

        // 3. 에코 중복 판별
        let remoteText = "I think we can do one that might be fun, if we have a little bit of time."
        assert(EchoDedup.isEcho(me: "Uh, and I might be able to do one that might be fun.", remote: remoteText), "에코 제거")
        assert(EchoDedup.isEcho(me: "If we have a little bit of time.", remote: remoteText), "에코 제거 2")
        assert(!EchoDedup.isEcho(me: "Let's move on to the budget review.", remote: remoteText), "무관한 문장 유지")
        assert(!EchoDedup.isEcho(me: "Uh, um.", remote: remoteText), "필러만 있으면 유지")
        assert(EchoDedup.isEcho(me: "Um, okay.", remote: "Okay."), "필러 무시 1단어 일치")
        assert(EchoDedup.isEcho(me: "음, 다음 주 금요일까지 예산안을 정리하겠습니다.", remote: "다음 주 금요일까지 예산안을 정리하겠습니다"), "한국어 에코")
        assert(!EchoDedup.isEcho(me: "그럼 배포 일정은 어떻게 되나요?", remote: "다음 주 금요일까지 예산안을 정리하겠습니다"), "한국어 무관 문장 유지")

        print("selfcheck OK")
    }
}

private extension JSONDecoder {
    static var iso: JSONDecoder { let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d }
}
