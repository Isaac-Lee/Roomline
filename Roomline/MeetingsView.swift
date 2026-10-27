import SwiftUI

/// 지난 미팅 목록과 노트·전사 뷰어.
struct MeetingsView: View {
    let session: SessionController
    @State private var records: [MeetingRecord] = []
    @State private var selection: MeetingRecord.ID?

    var body: some View {
        NavigationSplitView {
            List(records, selection: $selection) { record in
                VStack(alignment: .leading, spacing: 2) {
                    Text(record.meta.title)
                    Text(stateLabel(record.meta.state))
                        .font(.caption)
                        .foregroundStyle(record.meta.state == .done ? Color.secondary : Color.orange)
                }
            }
            .navigationSplitViewColumnWidth(min: 200, ideal: 240)
            .toolbar {
                Button("새로고침", systemImage: "arrow.clockwise") { reload() }
            }
        } detail: {
            if let record = records.first(where: { $0.id == selection }) {
                MeetingDetail(record: record, session: session)
                    .id(record.id)
            } else {
                Text("미팅을 선택하세요").foregroundStyle(.secondary)
            }
        }
        .frame(minWidth: 760, minHeight: 480)
        .onAppear(perform: reload)
        // 노트 생성이 끝나면 목록 상태를 갱신한다.
        .onChange(of: session.state) { reload() }
        .onChange(of: session.notesJob) { reload() }
    }

    private func reload() {
        records = TranscriptStore.list()
        if selection == nil { selection = records.first?.id }
    }

    private func stateLabel(_ state: MeetingState) -> String {
        switch state {
        case .recording: "중단됨"
        case .finalizing: "노트 생성 중"
        case .done: "완료"
        case .failed: "노트 실패"
        }
    }
}

private struct MeetingDetail: View {
    let record: MeetingRecord
    let session: SessionController
    @State private var tab = 0
    @State private var notes: String?
    @State private var lines: [TranscriptLine] = []
    @State private var diarizing = false
    @State private var diarizeError: String?
    @State private var names: [Int: String] = [:]
    @State private var namesChanged = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(record.meta.title).font(.title2.bold())
                Spacer()
                Button("Finder에서 열기") { NSWorkspace.shared.activateFileViewerSelecting([record.folder]) }
                Button(diarizing ? "화자 구분 중…" : "화자 구분") { diarize() }
                    .disabled(diarizing)
                Button("노트 다시 만들기") { session.regenerateNotes(record) }
                    .disabled(session.notesJob == record.folder || lines.isEmpty)
            }
            if let diarizeError { Text(diarizeError).font(.caption).foregroundStyle(.red) }
            if !speakerNumbers.isEmpty {
                HStack {
                    Text("화자").font(.caption).foregroundStyle(.secondary)
                    ForEach(speakerNumbers, id: \.self) { n in
                        TextField("상대 \(n)", text: Binding(get: { names[n] ?? "" }, set: { names[n] = $0 }))
                            .textFieldStyle(.roundedBorder)
                            .frame(maxWidth: 120)
                            .onSubmit { rename(n) }
                    }
                    if namesChanged {
                        Button("이름을 반영해 노트 다시 만들기") {
                            namesChanged = false
                            session.regenerateNotes(record)
                        }
                        .disabled(session.notesJob == record.folder)
                    }
                }
            }
            Picker("", selection: $tab) {
                Text("노트").tag(0)
                Text("전사 (\(lines.count))").tag(1)
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            if tab == 0 {
                ScrollView {
                    Text(notesText)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                List(lines) { line in
                    HStack(alignment: .firstTextBaseline) {
                        Text(NotesGenerator.clock(line.segment.start))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                        Text(line.speakerName)
                            .font(.caption.bold())
                            .foregroundStyle(color(of: line))
                        VStack(alignment: .leading) {
                            Text(line.segment.text)
                            if let translation = line.translation {
                                Text(translation).foregroundStyle(.secondary)
                            }
                        }
                        .textSelection(.enabled)
                    }
                }
            }
        }
        .padding()
        // 노트 작업이 끝나면(notesJob이 바뀌면) 노트·전사를 다시 읽는다.
        .task(id: session.notesJob) {
            notes = try? String(contentsOf: record.notesURL, encoding: .utf8)
            lines = TranscriptStore.loadTranscript(in: record.folder)
            names = TranscriptStore.readMeta(in: record.folder)?.speakerNames ?? [:]
        }
    }

    private var speakerNumbers: [Int] { Array(Set(lines.compactMap(\.remoteSpeaker))).sorted() }

    private func rename(_ n: Int) {
        try? VoiceProfiles.assign(speaker: n, name: names[n] ?? "", in: record.folder)
        lines = TranscriptStore.loadTranscript(in: record.folder)
        namesChanged = true
    }

    private static let palette: [Color] = [.blue, .purple, .orange, .pink, .teal, .brown]

    private func color(of line: TranscriptLine) -> Color {
        if line.segment.speaker == .me { return .green }
        return Self.palette[((line.remoteSpeaker ?? 1) - 1) % Self.palette.count]
    }

    private func diarize() {
        diarizing = true
        diarizeError = nil
        Task {
            do { _ = try await Diarizer.labelSpeakers(folder: record.folder) } catch { diarizeError = error.localizedDescription }
            lines = TranscriptStore.loadTranscript(in: record.folder)
            names = TranscriptStore.readMeta(in: record.folder)?.speakerNames ?? [:]
            diarizing = false
        }
    }

    private var notesText: AttributedString {
        guard let notes else { return AttributedString("아직 노트가 없습니다.") }
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return (try? AttributedString(markdown: notes, options: options)) ?? AttributedString(notes)
    }
}
