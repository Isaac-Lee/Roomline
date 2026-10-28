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
                MeetingDetail(record: record, session: session, onChange: reload)
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
        if !records.contains(where: { $0.id == selection }) { selection = records.first?.id }
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
    let onChange: () -> Void
    @State private var tab = 0
    @State private var title = ""
    @State private var confirmDelete = false
    @State private var notes: String?
    @State private var lines: [TranscriptLine] = []
    @State private var diarizing = false
    @State private var diarizeError: String?
    @State private var names: [Int: String] = [:]
    @State private var namesChanged = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                TextField("미팅 이름", text: $title)
                    .textFieldStyle(.plain)
                    .font(.title2.bold())
                    .onSubmit(rename)
                    .disabled(busy)
                Spacer()
                Button("삭제", systemImage: "trash", role: .destructive) { confirmDelete = true }
                    .disabled(busy)
                    .confirmationDialog("이 미팅을 휴지통으로 옮길까요?", isPresented: $confirmDelete) {
                        Button("휴지통으로 이동", role: .destructive, action: delete)
                    } message: {
                        Text("전사·노트·녹음이 함께 이동합니다. 휴지통에서 되살릴 수 있습니다.")
                    }
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
            title = TranscriptStore.readMeta(in: record.folder)?.title ?? record.meta.title
        }
    }

    private var busy: Bool { session.isBusy(record.folder) }

    /// meta.json의 제목과 노트 첫 줄("# 제목")을 함께 바꾼다.
    private func rename() {
        let newTitle = title.trimmingCharacters(in: .whitespaces)
        guard !newTitle.isEmpty, var meta = TranscriptStore.readMeta(in: record.folder) else { return }
        meta.title = newTitle
        try? TranscriptStore.write(meta, to: record.folder)
        if let notes, notes.hasPrefix("# ") {
            let body = notes.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false).dropFirst().joined()
            let renamed = "# \(newTitle)\n" + body
            try? renamed.write(to: record.notesURL, atomically: true, encoding: .utf8)
            self.notes = renamed
        }
        onChange()
    }

    /// 지우지 않고 휴지통으로 옮겨 되살릴 수 있게 한다.
    private func delete() {
        try? FileManager.default.trashItem(at: record.folder, resultingItemURL: nil)
        session.refreshUnfinishedMeetings()
        onChange()
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
