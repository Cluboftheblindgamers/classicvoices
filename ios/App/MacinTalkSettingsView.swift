import SwiftUI
import UniformTypeIdentifiers

/// MacinTalk controls use the same file channel as the rest of Classic Voices.
/// No separate App Group settings copy can drift away from VoiceOver's copy.
struct MacinTalkSettingsView: View {
    @Environment(VoiceLibrary.self) private var library
    @Environment(\.dismiss) private var dismiss
    @State private var generation: Generation = .snowleopard
    @State private var showingPronunciations = false
    @State private var importing = false
    @State private var exporting = false
    @State private var exportDocument = MacinTalkSettingsDocument()
    @State private var transferMessage: String?
    @AccessibilityFocusState private var pronunciationFocus: Bool

    private var profile: PantheraSettings { library.settings.macinTalkSettings(generation) }
    private func binding<T>(_ key: WritableKeyPath<PantheraSettings, T>) -> Binding<T> {
        Binding(get: { profile[keyPath: key] }, set: { value in
            library.updateSettings {
                var profile = $0.macinTalkSettings(generation)
                profile[keyPath: key] = value
                profile.rate = min(profile.rate, profile.rateLimit)
                $0.macinTalk[generation.rawValue] = profile
            }
        })
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Toggle("Use Panthera speech behavior", isOn: Binding(
                        get: { library.settings.macinTalkCompatibility },
                        set: { value in library.updateSettings { $0.macinTalkCompatibility = value } }))
                } footer: {
                    Text("Applies to Tiger, Leopard, Snow Leopard and Lion MacinTalk voices. Vocalizer voices keep their existing behavior.")
                }
                Section {
                    Picker("Generation", selection: $generation) {
                        ForEach(Generation.allCases) { Text($0.label).tag($0) }
                    }
                    #if os(macOS)
                    .pickerStyle(.radioGroup)
                    #endif
                }
                Group {
                    Section("Voice") {
                        Toggle("Use default volume", isOn: Binding(get: { profile.volume < 0 },
                            set: { binding(\.volume).wrappedValue = $0 ? -1 : generation.defaultVolume }))
                        if profile.volume >= 0 {
                            Stepper("Volume: \(profile.volume) percent", value: binding(\.volume), in: 0...100)
                        }
                        Toggle("Follow VoiceOver speaking rate", isOn: Binding(get: { profile.rate == 0 },
                            set: { binding(\.rate).wrappedValue = $0 ? 0 : 180 }))
                        if profile.rate > 0 {
                            Stepper("Fixed rate: \(profile.rate) words per minute", value: binding(\.rate),
                                    in: 80...profile.rateLimit, step: 10)
                        }
                        Toggle("Rate boost", isOn: binding(\.rateBoost))
                        LabeledContent("Inflection", value: "\(profile.inflection)")
                        Slider(value: Binding(get: { Double(profile.inflection) },
                                              set: { binding(\.inflection).wrappedValue = Int($0) }), in: 0...200, step: 1)
                            .accessibilityLabel("Inflection")
                            .accessibilityValue("\(profile.inflection), VoiceOver default 100")
                    }
                    Section("Pronunciation") {
                        Picker("Number reading", selection: binding(\.numbers)) {
                            Text("Engine’s original reading").tag(PantheraSettings.NumberStyle.off)
                            Text("Correct problem numbers").tag(PantheraSettings.NumberStyle.fix)
                            Text("Read numbers as words").tag(PantheraSettings.NumberStyle.words)
                        }
                        Toggle("Expand abbreviations", isOn: binding(\.expandAbbreviations))
                        Toggle("Expand dates", isOn: binding(\.expandDates))
                        Toggle("Read capitalized headings as words", isOn: binding(\.capitalsAsWords))
                        if generation == .leopard {
                            Toggle("Read 24-hour times as written", isOn: binding(\.twentyFourHour))
                        }
                        Button("Pronunciation corrections…") { showingPronunciations = true }
                            .accessibilityFocused($pronunciationFocus)
                    }
                    Section {
                        if generation.supportsPhrasing {
                            Picker("Engine phrase breaks", selection: binding(\.phrasing)) {
                                Text("Engine default").tag(PantheraSettings.Phrasing.leopard)
                                Text("Fewest").tag(PantheraSettings.Phrasing.fewest)
                                Text("Fewer").tag(PantheraSettings.Phrasing.fewer)
                                Text("More").tag(PantheraSettings.Phrasing.more)
                                Text("Most").tag(PantheraSettings.Phrasing.most)
                            }
                        }
                        Toggle("Natural pauses between announcement parts", isOn: binding(\.naturalPauses))
                        Toggle("Classic VoiceOver commas and pauses", isOn: binding(\.macPauses))
                        Toggle("Quick interruptions", isOn: binding(\.quickInterrupt))
                    } header: { Text("Phrasing") } footer: {
                        Text("Quick interruptions splits long announcements at clauses. This can change phrasing and Alex’s breaths; it is off by default.")
                    }
                    Section {
                        Toggle("Allow embedded speech commands", isOn: binding(\.acceptCommands))
                        Toggle("Reset commands after each announcement", isOn: binding(\.resetCommands))
                    } header: { Text("Speech commands") }
                }
                .disabled(!library.settings.macinTalkCompatibility)
                Section {
                    Button("Import Panthera or Classic settings…") { importing = true }
                    Button("Export settings…") {
                        do {
                            exportDocument = MacinTalkSettingsDocument(data: try PantheraSettingsTransfer.exported(library.settings))
                            exporting = true
                        } catch { transferMessage = error.localizedDescription }
                    }
                } header: { Text("Settings files") } footer: {
                    Text("Panthera property lists import MacinTalk settings and scoped pronunciations while keeping Vocalizer settings. Classic exports restore all speech settings. Importing turns spoken-text logging off.")
                }
                Section {
                    Toggle("Log spoken text", isOn: Binding(get: { library.settings.logSpokenText },
                        set: { value in library.updateSettings { $0.logSpokenText = value } }))
                } header: { Text("Diagnostics") } footer: {
                    Text("Off by default. When enabled, text read by VoiceOver is written to the device’s system log for troubleshooting. Turn it off after recording the problem.")
                }
            }
            .formStyle(.grouped)
            .navigationTitle("MacinTalk settings")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        .sheet(isPresented: $showingPronunciations, onDismiss: { pronunciationFocus = true }) {
            MacinTalkPronunciationsView()
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.propertyList, .json]) { result in
            do {
                let url = try result.get()
                let access = url.startAccessingSecurityScopedResource()
                defer { if access { url.stopAccessingSecurityScopedResource() } }
                let settings = try PantheraSettingsTransfer.imported(Data(contentsOf: url), preserving: library.settings)
                library.updateSettings { $0 = settings }
                transferMessage = "Settings imported. Spoken-text logging is off."
            } catch { transferMessage = error.localizedDescription }
        }
        .fileExporter(isPresented: $exporting, document: exportDocument, contentType: .json,
                      defaultFilename: "Classic Voices Settings") { result in
            if case .failure(let error) = result { transferMessage = error.localizedDescription }
        }
        .alert("Settings", isPresented: Binding(get: { transferMessage != nil }, set: { if !$0 { transferMessage = nil } })) {
            Button("OK") { transferMessage = nil }
        } message: { Text(transferMessage ?? "") }
        #if os(macOS)
        .frame(minWidth: 560, minHeight: 620)
        #endif
    }
}

private struct MacinTalkSettingsDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }
    var data = Data()
    init(data: Data = Data()) { self.data = data }
    init(configuration: ReadConfiguration) throws { data = configuration.file.regularFileContents ?? Data() }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents: data) }
}

struct MacinTalkPronunciationsView: View {
    @Environment(VoiceLibrary.self) private var library
    @Environment(\.dismiss) private var dismiss
    @State private var editing: Pronunciation?
    @AccessibilityFocusState private var addFocus: Bool

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    if library.settings.macinTalkPronunciations.isEmpty { Text("No pronunciation corrections yet.") }
                    ForEach(library.settings.macinTalkPronunciations) { entry in
                        Button { editing = entry } label: {
                            VStack(alignment: .leading) {
                                Text(entry.match)
                                Text(entry.replacement).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        .accessibilityElement(children: .combine)
                        .accessibilityHint("Edit pronunciation and scope")
                        .accessibilityAction(named: "Delete") { remove(entry.id) }
                        .contextMenu { Button("Delete", role: .destructive) { remove(entry.id) } }
                    }
                    .onDelete { offsets in library.updateSettings { $0.macinTalkPronunciations.remove(atOffsets: offsets) } }
                    Button("Add a correction…") { editing = Pronunciation() }
                        .accessibilityFocused($addFocus)
                } footer: {
                    Text("Corrections can apply to all MacinTalk voices, selected generations, or specific voices. Longer matches take priority; voice-specific matches win ties.")
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Pronunciations")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        .sheet(item: $editing, onDismiss: { addFocus = true }) { entry in
            MacinTalkPronunciationEditor(entry: entry) { value in
                library.updateSettings {
                    if let index = $0.macinTalkPronunciations.firstIndex(where: { $0.id == value.id }) {
                        $0.macinTalkPronunciations[index] = value
                    } else { $0.macinTalkPronunciations.append(value) }
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 520, minHeight: 500)
        #endif
    }
    private func remove(_ id: UUID) { library.updateSettings { $0.macinTalkPronunciations.removeAll { $0.id == id } } }
}

private struct MacinTalkPronunciationEditor: View {
    enum Scope: String, CaseIterable { case all = "All MacinTalk voices", generations = "Selected generations", voices = "Specific voices" }
    @Environment(VoiceLibrary.self) private var library
    @Environment(\.dismiss) private var dismiss
    @State var entry: Pronunciation
    let save: (Pronunciation) -> Void
    @State private var scope: Scope
    init(entry: Pronunciation, save: @escaping (Pronunciation) -> Void) {
        self.entry = entry; self.save = save
        _scope = State(initialValue: entry.voiceIDs != nil ? .voices : entry.generations.isEmpty ? .all : .generations)
    }
    var body: some View {
        NavigationStack {
            Form {
                TextField("Written text", text: $entry.match)
                TextField(entry.phonemes ? "MacinTalk phonemes" : "Say instead", text: $entry.replacement)
                Toggle("Use MacinTalk phonemes", isOn: $entry.phonemes)
                Toggle("Match capitalization", isOn: $entry.matchCase)
                Toggle("Whole words only", isOn: $entry.wholeWords)
                Picker("Apply to", selection: $scope) {
                    ForEach(Scope.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                if scope == .generations {
                    ForEach(Generation.allCases) { generation in
                        Toggle(generation.label, isOn: Binding(get: { entry.generations.contains(generation) }, set: {
                            if $0 { entry.generations.insert(generation) } else { entry.generations.remove(generation) }
                        }))
                    }
                }
                if scope == .voices {
                    let voices = library.items.filter { $0.isInstalled && $0.entry?.key.hasPrefix("mt") == true }
                    if voices.isEmpty { Text("Import a MacinTalk voice to select it here.") }
                    ForEach(voices) { item in
                        if let key = item.entry?.key, let id = MacinTalkCompatibility.pronunciationID(for: key) {
                            Toggle("\(item.version.name) \(item.name)", isOn: Binding(
                                get: { entry.voiceIDs?.contains(id) == true }, set: {
                                    var selected = entry.voiceIDs ?? []
                                    if $0 { selected.insert(id) } else { selected.remove(id) }
                                    entry.voiceIDs = selected
                                }))
                        }
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Pronunciation correction")
            .onChange(of: scope) { _, value in
                if value == .voices { entry.voiceIDs = [] }
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        if scope == .all { entry.generations = []; entry.voiceIDs = nil }
                        if scope == .generations { entry.voiceIDs = nil }
                        if scope == .voices { entry.voiceIDs = entry.voiceIDs ?? [] }
                        save(entry); dismiss()
                    }
                    .disabled(entry.match.isEmpty || entry.replacement.isEmpty || (scope == .generations && entry.generations.isEmpty))
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 520, minHeight: 500)
        #endif
    }
}
