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

        // 2. 10분 단위 구간 나누기
        let long = (0..<25).map { i in
            TranscriptLine(segment: Segment(id: UUID(), speaker: .remote, start: Double(i * 60), end: Double(i * 60 + 5), text: "s\(i)"))
        }
        let chunks = NotesGenerator.chunks(long)
        assert(chunks.map(\.count) == [10, 10, 5], "구간 크기 \(chunks.map(\.count))")
        assert(NotesGenerator.format([long[11]]) == "[11:00] 상대: s11")
        assert(NotesGenerator.stripThinking("<think>hmm</think>\n## 요약") == "## 요약")

        print("selfcheck OK")
    }
}
