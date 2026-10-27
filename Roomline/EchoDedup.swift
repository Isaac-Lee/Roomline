import Foundation

/// 마이크 채널이 스피커 소리를 다시 받아 적은 중복(에코)인지 텍스트로 판별한다.
enum EchoDedup {
    private static let fillers: Set<String> = ["uh", "um", "uhm", "hmm", "mm", "ah", "er"]

    static func words(_ text: String) -> [String] {
        text.lowercased()
            .split { !$0.isLetter && !$0.isNumber && $0 != "'" }
            .map(String.init)
            .filter { !fillers.contains($0) }
    }

    /// me 단어의 60% 이상이 remote 텍스트에 있으면 에코 (한 단어는 완전 일치).
    static func isEcho(me: String, remote: String) -> Bool {
        let m = words(me), r = Set(words(remote))
        guard !m.isEmpty else { return false }
        if m.count == 1 { return r.count == 1 && r.contains(m[0]) }
        return Double(m.filter(r.contains).count) / Double(m.count) >= 0.6
    }
}
