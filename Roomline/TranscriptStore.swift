import Foundation

struct MeetingRecord: Identifiable {
    let folder: URL
    var meta: MeetingMeta
    var id: UUID { meta.id }
    var notesURL: URL { folder.appending(path: "notes.md") }
}

struct TranscriptLine: Identifiable {
    let segment: Segment
    var translation: String?
    var remoteSpeaker: Int?   // 화자 구분 결과(1부터)
    var speakerName: String {
        if segment.speaker == .me { return "나" }
        return remoteSpeaker.map { "상대 \($0)" } ?? "상대"
    }
    var id: UUID { segment.id }
}

/// 미팅 폴더 하나. transcript.jsonl은 append-only라 앱이 죽어도 그 시점까지 남는다.
actor TranscriptStore {
    static let root = URL.applicationSupportDirectory.appending(path: "MeetingCaptions/meetings")

    let folder: URL
    private(set) var meta: MeetingMeta
    private let handle: FileHandle

    init(startedAt: Date = .now) throws {
        let id = UUID()
        let stamp = DateFormatter()
        stamp.dateFormat = "yyyy-MM-dd'T'HHmm"
        let title = DateFormatter()
        title.dateFormat = "yyyy-MM-dd HH:mm 미팅"

        folder = Self.root.appending(path: "\(stamp.string(from: startedAt))_\(id.uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let transcript = folder.appending(path: "transcript.jsonl")
        FileManager.default.createFile(atPath: transcript.path, contents: nil)
        handle = try FileHandle(forWritingTo: transcript)

        meta = MeetingMeta(id: id, title: title.string(from: startedAt), startedAt: startedAt, endedAt: nil, state: .recording)
        try Self.write(meta, to: folder)
    }

    deinit {
        try? handle.close()
    }

    func append(_ event: TranscriptEvent) {
        do {
            var line = try Self.encoder.encode(event)
            line.append(0x0A)
            try handle.seekToEnd()
            try handle.write(contentsOf: line)
        } catch {
            print("transcript append failed:", error)
        }
    }

    /// 끝난 미팅의 transcript.jsonl에 이벤트를 덧붙인다(화자 구분 결과용).
    static func append(_ events: [TranscriptEvent], to folder: URL) throws {
        var data = Data()
        for event in events { data.append(try encoder.encode(event)); data.append(0x0A) }
        let handle = try FileHandle(forWritingTo: folder.appending(path: "transcript.jsonl"))
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: data)
    }

    func update(_ change: (inout MeetingMeta) -> Void) {
        change(&meta)
        try? Self.write(meta, to: folder)
    }

    // MARK: 읽기

    static func list() -> [MeetingRecord] {
        let folders = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        return folders.compactMap { folder in
            guard let meta = readMeta(in: folder) else { return nil }
            return MeetingRecord(folder: folder, meta: meta)
        }
        .sorted { $0.meta.startedAt > $1.meta.startedAt }
    }

    static func readMeta(in folder: URL) -> MeetingMeta? {
        guard let data = try? Data(contentsOf: folder.appending(path: "meta.json")) else { return nil }
        return try? decoder.decode(MeetingMeta.self, from: data)
    }

    static func write(_ meta: MeetingMeta, to folder: URL) throws {
        try encoder.encode(meta).write(to: folder.appending(path: "meta.json"), options: .atomic)
    }

    /// 세그먼트와 나중에 도착한 번역을 합쳐 시간순으로 돌려준다. 깨진 줄(죽는 순간의 마지막 줄)은 건너뛴다.
    static func loadTranscript(in folder: URL) -> [TranscriptLine] {
        guard let text = try? String(contentsOf: folder.appending(path: "transcript.jsonl"), encoding: .utf8) else { return [] }
        var lines: [TranscriptLine] = []
        var indexByID: [UUID: Int] = [:]
        for row in text.split(separator: "\n") {
            guard let event = try? decoder.decode(TranscriptEvent.self, from: Data(row.utf8)) else { continue }
            switch event {
            case .segment(let segment):
                indexByID[segment.id] = lines.count
                lines.append(TranscriptLine(segment: segment))
            case .translation(let id, let translation):
                if let index = indexByID[id] { lines[index].translation = translation }
            case .speakerLabel(let id, let speaker):
                if let index = indexByID[id] { lines[index].remoteSpeaker = speaker }
            }
        }
        return lines.sorted { $0.segment.start < $1.segment.start }
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}
