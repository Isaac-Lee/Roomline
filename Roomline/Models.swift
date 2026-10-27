import Foundation

enum Speaker: String, Codable { case remote, me }

struct Segment: Codable, Identifiable {
    let id: UUID
    let speaker: Speaker
    let start: TimeInterval   // 미팅 시작 기준 초
    let end: TimeInterval
    let text: String          // 영어 확정 전사
}

enum TranscriptEvent: Codable {
    case segment(Segment)
    case translation(segmentID: UUID, text: String)
    case speakerLabel(segmentID: UUID, speaker: Int)   // 미팅 후 화자 구분 결과(마지막 라벨이 우선)
}

enum MeetingState: String, Codable { case recording, finalizing, done, failed }

struct MeetingMeta: Codable {
    let id: UUID
    var title: String
    let startedAt: Date
    var endedAt: Date?
    var state: MeetingState
}
