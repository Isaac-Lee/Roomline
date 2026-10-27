import Foundation

/// 화자 목소리 프로필. 미팅마다 speakers.json(화자 번호 → 중심 임베딩)을 남기고,
/// 사용자가 이름을 붙이면 전역 voices.json에 누적해 다음 미팅에서 자동으로 이름을 채운다.
enum VoiceProfiles {
    struct Profile: Codable {
        var name: String
        var embedding: [Float]   // L2 정규화
        var count: Int
    }

    // ponytail: FluidAudio 군집 기준(유클리드 0.6 ≈ 코사인 0.82)에서 잡은 값. 실제 통화로 보정 필요.
    static let matchThreshold: Float = 0.8

    static var fileURL = URL.applicationSupportDirectory.appending(path: "MeetingCaptions/voices.json")

    static func normalized(_ v: [Float]) -> [Float] {
        let norm = v.reduce(0) { $0 + $1 * $1 }.squareRoot()
        return norm > 0 ? v.map { $0 / norm } : v
    }

    /// 둘 다 정규화돼 있으므로 내적이 코사인 유사도.
    static func cosine(_ a: [Float], _ b: [Float]) -> Float { zip(a, b).reduce(0) { $0 + $1.0 * $1.1 } }

    static func load() -> [Profile] {
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        return (try? JSONDecoder().decode([Profile].self, from: data)) ?? []
    }

    static func saveCentroids(_ centroids: [Int: [Float]], to folder: URL) throws {
        let data = try JSONEncoder().encode(Dictionary(uniqueKeysWithValues: centroids.map { (String($0.key), $0.value) }))
        try data.write(to: folder.appending(path: "speakers.json"), options: .atomic)
    }

    static func centroids(in folder: URL) -> [Int: [Float]] {
        guard let data = try? Data(contentsOf: folder.appending(path: "speakers.json")),
              let raw = try? JSONDecoder().decode([String: [Float]].self, from: data) else { return [:] }
        return Dictionary(uniqueKeysWithValues: raw.compactMap { k, v in Int(k).map { ($0, v) } })
    }

    /// 화자별 최고 유사도 순(greedy)으로 프로필 이름을 배정한다. 같은 이름·같은 프로필은 한 번만.
    static func match(_ centroids: [Int: [Float]], profiles: [Profile]) -> [(speaker: Int, name: String, similarity: Float)] {
        var pairs: [(speaker: Int, name: String, similarity: Float)] = []
        for (n, c) in centroids { for p in profiles { pairs.append((n, p.name, cosine(c, p.embedding))) } }
        var result: [(speaker: Int, name: String, similarity: Float)] = []
        for pair in pairs.sorted(by: { $0.similarity > $1.similarity }) where pair.similarity >= matchThreshold {
            if result.contains(where: { $0.speaker == pair.speaker || $0.name == pair.name }) { continue }
            result.append(pair)
        }
        return result
    }

    /// 사용자가 화자 번호에 이름을 붙인다(빈 문자열이면 이름 제거). 미팅 meta와 전역 프로필을 함께 갱신.
    static func assign(speaker: Int, name: String, in folder: URL) throws {
        guard var meta = TranscriptStore.readMeta(in: folder) else { return }
        let name = name.trimmingCharacters(in: .whitespaces)
        var names = meta.speakerNames ?? [:]
        guard names[speaker] != (name.isEmpty ? nil : name) else { return }
        names[speaker] = name.isEmpty ? nil : name
        meta.speakerNames = names.isEmpty ? nil : names
        try TranscriptStore.write(meta, to: folder)

        guard !name.isEmpty, let centroid = centroids(in: folder)[speaker] else { return }
        var profiles = load()
        if let i = profiles.firstIndex(where: { $0.name == name }) {
            let p = profiles[i]
            let sum = zip(p.embedding, centroid).map { $0 * Float(p.count) + $1 }
            profiles[i] = Profile(name: name, embedding: normalized(sum), count: p.count + 1)
        } else {
            profiles.append(Profile(name: name, embedding: centroid, count: 1))
        }
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(profiles).write(to: fileURL, options: .atomic)
    }
}
