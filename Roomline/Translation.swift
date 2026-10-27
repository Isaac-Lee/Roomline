import Foundation
import Translation

/// Ollama 기반 번역기 등으로 교체할 수 있게 둔 경계.
protocol Translator: Sendable {
    func translate(_ text: String) async throws -> String
}

/// Apple 온디바이스 번역 (en → ko). 언어팩이 설치돼 있어야 한다.
actor AppleTranslator: Translator {
    static let source = Locale.Language(identifier: "en")
    static let target = Locale.Language(identifier: "ko")

    private let session = TranslationSession(
        installedSource: AppleTranslator.source,
        target: AppleTranslator.target,
        preferredStrategy: .lowLatency)

    static func isInstalled() async -> Bool {
        await LanguageAvailability().status(from: source, to: target) == .installed
    }

    func translate(_ text: String) async throws -> String {
        try await session.translate(text).targetText
    }
}
