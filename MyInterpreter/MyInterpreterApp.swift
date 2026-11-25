import SwiftUI
import Translation

@main
struct MyInterpreterApp: App {
    var body: some Scene {
        Window("MyInterpreter", id: "conversation") { ConversationView() }
            .defaultSize(width: 960, height: 610)
    }
}

struct ConversationView: View {
    @StateObject private var speech = LiveSpeech()
    @AppStorage("targetLanguage") private var target = "ko"
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
                Button {
                    if speech.running { speech.stop() }
                    else { Task { await speech.start() } }
                } label: {
                    Label(speech.running ? "Stop" : "Start listening",
                          systemImage: speech.running ? "stop.fill" : "mic.fill")
                }
                .buttonStyle(.borderedProminent)
            }
            if !speech.message.isEmpty {
                Label(speech.message, systemImage: speech.running ? "waveform" : "info.circle")
                    .foregroundStyle(.secondary)
            }
            Divider()
            HStack {
                Text("English").font(.headline).frame(maxWidth: .infinity, alignment: .leading)
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
            if speech.captions.isEmpty {
                ContentUnavailableView("Waiting for English speech", systemImage: "waveform",
                    description: Text("Start listening and speak into your Mac’s selected microphone."))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 16) {
                            ForEach(speech.captions) { line in
                                HStack(alignment: .top, spacing: 16) {
                                    column(line.english)
                                    Divider()
                                    column(line.translation.isEmpty ? "…" : line.translation)
                                }
                                Divider()
                            }
                            Color.clear.frame(height: 1).id("end")
                        }
                    }.onChange(of: speech.captions.last?.english) { proxy.scrollTo("end") }
                }
            }
        }
        .padding(24).frame(minWidth: 640, minHeight: 340)
        .task {
            let available = await LanguageAvailability().supportedLanguages
            languages = available.filter { $0.languageCode?.identifier != "en" }
                .sorted { name($0.minimalIdentifier).localizedCompare(name($1.minimalIdentifier)) == .orderedAscending }
            if !speech.captions.isEmpty { configure() }
        }
        .onChange(of: speech.captions.isEmpty) { if !speech.captions.isEmpty { configure() } }
        .onChange(of: target) { configure() }
        .onDisappear { speech.stop() }
        .translationTask(config) { session in
            let version = revision
            do {
                try await session.prepareTranslation()
                while !Task.isCancelled && version == revision {
                    if let line = speech.captions.first(where: { $0.english != $0.translatedSource }) {
                        let response = try await session.translate(line.english)
                        guard !Task.isCancelled, version == revision else { return }
                        if let i = speech.captions.firstIndex(where: { $0.id == line.id }) {
                            speech.captions[i].translation = response.targetText
                            speech.captions[i].translatedSource = line.english
                        }
                    }
                    try await Task.sleep(for: .milliseconds(450))
                }
            } catch {
                if !Task.isCancelled && version == revision { translationIssue = error.localizedDescription }
            }
        }
    }

    private func configure() {
        revision = UUID()
        translationIssue = ""
        for i in speech.captions.indices {
            speech.captions[i].translation = ""
            speech.captions[i].translatedSource = ""
        }
        guard !speech.captions.isEmpty else { return }
        let language = Locale.Language(identifier: target)
        if config?.target == language { config?.invalidate() }
        else { config = .init(source: .init(identifier: "en"), target: language) }
    }

    private func column(_ text: String) -> some View {
        Text(text).font(.title3).textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .topLeading)
    }
}
