import AVFoundation
import Speech
import SwiftUI
import Translation
import UniformTypeIdentifiers

private struct ConversationExport: Transferable {
    let transcript: Transcript
    let language: String

    var text: String { transcript.exportText(language: language) }

    static var transferRepresentation: some TransferRepresentation {
        ProxyRepresentation(exporting: \.text)
    }
}

@main
struct MyInterpreterApp: App {
    var body: some Scene {
        Window("MyInterpreter", id: "conversation") { ConversationView() }
            .defaultSize(width: 960, height: 610)
    }
}

struct ConversationView: View {
    @StateObject private var speech = LiveSpeech()
    @AppStorage("microphone") private var microphone = ""
    @AppStorage("englishDialect") private var spoken = "en-AU"
    @AppStorage("roomMode") private var roomMode = false
    @AppStorage("recognitionVocabulary") private var vocabulary = ""
    @State private var saveError: String?
    @State private var showInputs = false
    @AppStorage("targetLanguage") private var target = "ko"
    @State private var inputLocales: [String] = []
    @State private var languages: [Locale.Language] = []
    @State private var config: TranslationSession.Configuration?
    @State private var translationIssue = ""
    @State private var revision = UUID()

    private func name(_ code: String) -> String {
        Locale.current.localizedString(forIdentifier: code) ?? code
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Live conversation").font(.largeTitle.bold())
                Spacer()
                Button { showInputs.toggle() } label: { Label("Input settings", systemImage: "slider.horizontal.3") }
                    .disabled(speech.running)
                    .popover(isPresented: $showInputs) { inputSettings }
                Button {
                    if speech.running { speech.stop() }
                    else { Task { await speech.start(deviceID: microphone, sourceLocale: spoken, roomMode: roomMode, vocabulary: vocabulary) } }
                } label: {
                    Label(speech.running ? "Stop" : "Start listening",
                          systemImage: speech.running ? "stop.fill" : "mic.fill")
                }
                .buttonStyle(.borderedProminent)
                .disabled(speech.finishing)
            }
            if !speech.message.isEmpty {
                Label(speech.message, systemImage: speech.running ? "waveform" : "info.circle")
                    .foregroundStyle(.secondary)
            }
            if !speech.speakerStatus.isEmpty {
                Text(speech.speakerStatus).font(.caption).foregroundStyle(.secondary)
            }
            Divider()
            HStack {
                spokenLanguagePicker.disabled(speech.running)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Picker("Translate to", selection: $target) {
                    if !languages.contains(where: { $0.minimalIdentifier == target }) {
                        Text(name(target)).tag(target)
                    }
                    ForEach(languages, id: \.minimalIdentifier) { language in
                        Text(name(language.minimalIdentifier)).tag(language.minimalIdentifier)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            if !translationIssue.isEmpty {
                HStack {
                    Text(translationIssue).foregroundStyle(.secondary)
                    Button("Retry") { configure() }
                }
            }
            Text("Current speech").font(.headline)
            ScrollView {
                captionRow(speech.transcript.live, placeholder: speech.running ? "Listening…" : "Waiting for speech")
            }
            .frame(height: 100)
            .padding(12)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
            HStack {
                Text("Conversation history").font(.headline)
                Spacer()
                Button { saveConversation() } label: { Label("Save…", systemImage: "square.and.arrow.down") }
                    .keyboardShortcut("s")
                ShareLink(item: export, preview: SharePreview("MyInterpreter conversation")) {
                    Label("Share", systemImage: "square.and.arrow.up")
                }
            }
            .disabled(!hasSpeech)
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        if speech.transcript.history.isEmpty {
                            Text("Completed phrases will appear here.").foregroundStyle(.secondary)
                        }
                        ForEach(speech.transcript.history) { line in
                            captionRow(line)
                            Divider()
                        }
                        Color.clear.frame(height: 1).id("end")
                    }
                }.onChange(of: speech.transcript.history.last?.id) { proxy.scrollTo("end") }
            }
        }
        .padding(24).frame(minWidth: 640, minHeight: 340)
        .task {
            let available = await LanguageAvailability(preferredStrategy: .highFidelity).supportedLanguages
            languages = available
                .sorted { name($0.minimalIdentifier).localizedCompare(name($1.minimalIdentifier)) == .orderedAscending }

        }
        .task(id: usesDictation) {
            var locales = await DictationTranscriber.supportedLocales
            if !usesDictation && SpeechTranscriber.isAvailable {
                locales += await SpeechTranscriber.supportedLocales
            }
            guard !Task.isCancelled else { return }
            inputLocales = Set(locales.map { $0.identifier(.bcp47) })
                .sorted { name($0).localizedCompare(name($1)) == .orderedAscending }
        }
        .onChange(of: pendingSource) { configure() }
        .onChange(of: target) {
            speech.transcript.clearTranslations()
            configure()
        }
        .alert("Couldn’t save conversation", isPresented: Binding(
            get: { saveError != nil }, set: { if !$0 { saveError = nil } }
        )) { Button("OK") { saveError = nil } } message: { Text(saveError ?? "") }
        .onDisappear { speech.stop() }
        .task(id: copyKey) {
            guard let key = copyKey else { return }
            while !Task.isCancelled, let line = speech.transcript.pendingTranslation,
                  languageID(line.sourceLocale) == key, languageID(target) == key {
                speech.transcript.applyTranslation(line.original, for: line)
                await Task.yield()
            }
        }
        .translationTask(config) { session in
            let version = revision
            do {
                try await session.prepareTranslation()
                while !Task.isCancelled && version == revision {
                    if let line = speech.transcript.pendingTranslation,
                       languageID(line.sourceLocale) == config?.source?.minimalIdentifier {
                        let response = try await session.translate(line.original)
                        guard !Task.isCancelled, version == revision else { return }
                        speech.transcript.applyTranslation(response.targetText, for: line)
                    }
                    try await Task.sleep(for: .milliseconds(450))
                }
            } catch {
                if !Task.isCancelled && version == revision { translationIssue = error.localizedDescription }
            }
        }
    }

    private var export: ConversationExport {
        ConversationExport(transcript: speech.transcript, language: name(target))
    }

    private func saveConversation() {
        let snapshot = export
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.plainText]
        panel.canCreateDirectories = true
        let date = Date.now.formatted(.iso8601.year().month().day())
        panel.nameFieldStringValue = "MyInterpreter-\(date).txt"
        panel.begin { result in
            guard result == .OK, let destination = panel.url else { return }
            do { try snapshot.text.write(to: destination, atomically: true, encoding: .utf8) }
            catch { saveError = error.localizedDescription }
        }
    }

    private func configure() {
        revision = UUID()
        translationIssue = ""
        guard let source = pendingSource, source != languageID(target) else { config = nil; return }
        let pair = TranslationSession.Configuration(source: .init(identifier: source),
                                                   target: .init(identifier: target), preferredStrategy: .highFidelity)
        if config?.source == pair.source && config?.target == pair.target { config?.invalidate() }
        else { config = pair }
    }

    private func languageID(_ identifier: String) -> String {
        let language = Locale.Language(identifier: identifier)
        return Locale.Language(languageCode: language.languageCode, script: language.script).minimalIdentifier
    }

    private var pendingSource: String? {
        speech.transcript.pendingTranslation.map { languageID($0.sourceLocale) }
    }

    private var copyKey: String? {
        pendingSource == languageID(target) ? pendingSource : nil
    }

    private var usesDictation: Bool {
        roomMode || vocabulary.split(separator: ",").contains { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    private var hasSpeech: Bool {
        speech.transcript.live != nil || !speech.transcript.history.isEmpty
    }

    private var spokenLanguagePicker: some View {
        Picker("Spoken language", selection: $spoken) {
            if !inputLocales.contains(spoken) { Text(name(spoken)).tag(spoken) }
            ForEach(inputLocales, id: \.self) { code in Text(name(code)).tag(code) }
        }
    }

    private var inputSettings: some View {
        Form {
            Picker("Microphone", selection: $microphone) {
                Text("System default").tag("")
                ForEach(AVCaptureDevice.DiscoverySession(deviceTypes: [.microphone, .external],
                              mediaType: .audio, position: .unspecified).devices, id: \.uniqueID) { device in
                    Text(device.localizedName).tag(device.uniqueID)
                }
            }
            spokenLanguagePicker
            Toggle("Room microphone (distant voices)", isOn: $roomMode)
            TextField("Names and terms", text: $vocabulary, prompt: Text("Separate words or phrases with commas"))
            Text("Room mode or custom terms use Apple’s on-device Dictation recognizer.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding().frame(width: 420)
    }

    private func captionRow(_ line: Caption?, placeholder: String = "") -> some View {
        VStack(alignment: .leading, spacing: 5) {
            if let line, line.sourceLocale != spoken {
                Text(name(line.sourceLocale)).font(.caption).foregroundStyle(.secondary)
            }
            if let speaker = line?.speaker {
                Text("Speaker \(speaker)").font(.caption.bold()).foregroundStyle(.secondary)
            }
            HStack(alignment: .top, spacing: 16) {
                column(line?.original ?? placeholder)
                Divider()
                column(line.map { $0.translation.isEmpty ? "…" : $0.translation } ?? "")
            }
        }
    }

    private func column(_ text: String) -> some View {
        Text(text).font(.title3).textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .topLeading)
    }
}
