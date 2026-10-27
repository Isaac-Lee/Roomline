import SwiftUI
import Translation

struct SettingsView: View {
    @Bindable var session: SessionController
    @AppStorage(SettingsKey.translateMine) private var translateMine = false
    @AppStorage(SettingsKey.echoGate) private var echoGate = "auto"
    @AppStorage(SettingsKey.meetingLanguage) private var meetingLanguage = "en"
    @AppStorage(SettingsKey.remoteLocale) private var remoteLocale = "en-US"
    @AppStorage(SettingsKey.ollamaModel) private var ollamaModel = SettingsKey.defaultOllamaModel
    @State private var download: TranslationSession.Configuration?
    @State private var downloadError: String?

    var body: some View {
        Form {
            Section("자막 패널") {
                Slider(value: $session.overlay.fontSize, in: 12...36, step: 1) {
                    Text("글자 크기 \(Int(session.overlay.fontSize))")
                }
                Slider(value: $session.overlay.backgroundOpacity, in: 0.2...1) {
                    Text("배경 불투명도 \(Int(session.overlay.backgroundOpacity * 100))%")
                }
                Toggle("클릭 통과 (⌃⌥X)", isOn: $session.overlay.clickThrough)
            }

            Section {
                Picker("미팅 언어", selection: $meetingLanguage) {
                    Text("영어").tag("en")
                    Text("한국어").tag("ko")
                }
                if meetingLanguage == "en" {
                    Toggle("내 발화도 한국어로 번역", isOn: $translateMine)
                }
                Picker("에코 게이트", selection: $echoGate) {
                    Text("자동(스피커로 들을 때만)").tag("auto")
                    Text("항상 켬").tag("on")
                    Text("끔").tag("off")
                }
                if meetingLanguage == "en" {
                Picker("상대 영어 억양", selection: $remoteLocale) {
                    Text("미국 (en-US)").tag("en-US")
                    Text("인도 (en-IN)").tag("en-IN")
                    Text("영국 (en-GB)").tag("en-GB")
                    Text("호주 (en-AU)").tag("en-AU")
                    Text("싱가포르 (en-SG)").tag("en-SG")
                    Text("캐나다 (en-CA)").tag("en-CA")
                }
                }
            } header: {
                Text("음성")
            } footer: {
                Text("스피커로 들으면 상대 발화가 \"나\"로 중복될 수 있어 상대 소리가 날 때 마이크를 무시합니다. 자동은 출력 장치가 바뀌면 미팅 중에도 따라갑니다. 켬/끔과 상대 영어 억양은 다음 미팅부터 적용됩니다.")
            }

            if meetingLanguage == "en" {
            Section("번역") {
                if session.translationMissing {
                    HStack {
                        Text("영어 → 한국어 언어팩이 설치되어 있지 않습니다.")
                        Spacer()
                        Button("다운로드") {
                            downloadError = nil
                            if download == nil {
                                download = .init(source: AppleTranslator.source, target: AppleTranslator.target)
                            } else {
                                download?.invalidate()
                            }
                        }
                    }
                    if let downloadError { Text(downloadError).foregroundStyle(.red) }
                } else {
                    Label("영어 → 한국어 언어팩 설치됨", systemImage: "checkmark.circle")
                }
            }
            }

            Section {
                TextField("Ollama 모델", text: $ollamaModel)
            } header: {
                Text("미팅 노트")
            } footer: {
                Text("`ollama pull \(ollamaModel)`로 먼저 받아 두세요. 노트는 미팅 폴더의 notes.md에 저장됩니다.")
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
        // 시스템 다운로드 확인 창을 띄우려면 SwiftUI 뷰에 붙은 세션이 필요하다.
        .translationTask(download) { translation in
            do {
                try await translation.prepareTranslation()
            } catch {
                downloadError = error.localizedDescription
            }
            await session.refreshTranslationAvailability()
        }
        .task { await session.refreshTranslationAvailability() }
    }
}
