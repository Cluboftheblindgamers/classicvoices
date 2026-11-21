import AppKit
import AVFoundation
import SwiftUI

/// Manage only copies with this app's exact extension identifiers. A side-by-
/// side Panthera trial must never remove stable Panthera or upstream Classic.
@MainActor final class VoiceInstallations: ObservableObject {
    struct Copy: Identifiable {
        let app: URL
        let extensions: [URL]
        var id: String { app.path }
    }
    @Published var copies: [Copy] = []
    @Published var busy = false
    @Published var report: String?
    private static let current = Bundle.main.bundleURL.resolvingSymlinksInPath()
    private static var identifiers: Set<String> {
        Set(extensions(in: current).compactMap { Bundle(url: $0)?.bundleIdentifier })
    }
    nonisolated private static let lsregister = "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
    nonisolated private static func run(_ path: String, _ arguments: [String]) -> String {
        let process = Process(), pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: path); process.arguments = arguments
        process.standardOutput = pipe; process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return error.localizedDescription }
        let result = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: result, as: UTF8.self)
    }
    nonisolated private static func extensions(in app: URL) -> [URL] {
        let directory = app.appendingPathComponent("Contents/PlugIns")
        return ((try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "appex" }
    }
    func refresh() {
        guard !busy else { return }
        busy = true
        let ids = Self.identifiers, current = Self.current
        Task.detached {
            let registry = Self.run("/usr/bin/pluginkit", ["-mAvvv"])
            var seen = Set<String>(), found: [Copy] = []
            for line in registry.split(separator: "\n") {
                let text = line.trimmingCharacters(in: .whitespaces)
                guard text.hasPrefix("Path = ") else { continue }
                let extensionURL = URL(fileURLWithPath: String(text.dropFirst(7))).resolvingSymlinksInPath()
                guard let id = Bundle(url: extensionURL)?.bundleIdentifier, ids.contains(id),
                      let range = extensionURL.path.range(of: ".app/Contents/PlugIns/") else { continue }
                let app = URL(fileURLWithPath: String(extensionURL.path[..<range.lowerBound]) + ".app")
                guard app != current, seen.insert(app.path).inserted else { continue }
                let matching = Self.extensions(in: app).filter { Bundle(url: $0)?.bundleIdentifier.map(ids.contains) == true }
                found.append(Copy(app: app, extensions: matching))
            }
            let sorted = found.sorted { $0.id < $1.id }
            await MainActor.run { self.copies = sorted; self.busy = false }
        }
    }
    func remove(_ copy: Copy, quit: Bool = false, removeData: Bool = false) {
        guard !busy else { return }
        // Revalidate on each operation, including after a confirmation dialog.
        let ids = Self.identifiers
        guard copy.app.pathExtension == "app", !copy.extensions.isEmpty,
              copy.extensions.allSatisfy({ Bundle(url: $0)?.bundleIdentifier.map(ids.contains) == true }) else {
            report = "This copy does not have this app’s voice identifiers."; return
        }
        busy = true
        let group = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup)
        Task.detached {
            for extensionURL in copy.extensions { _ = Self.run("/usr/bin/pluginkit", ["-r", extensionURL.path]) }
            _ = Self.run(Self.lsregister, ["-u", copy.app.path])
            var result = "Unregistered this copy’s voices."
            if removeData {
                // Only named data folders; the system owns the containers.
                var folders = [URL]()
                if let group { folders += ["Voices", "EnhancedVoices", "Native"].map { group.appendingPathComponent($0) } }
                for id in ids where !id.contains("/") {
                    folders.append(FileManager.default.homeDirectoryForCurrentUser
                        .appendingPathComponent("Library/Containers/\(id)/Data/Library/Application Support/EnhancedVoices"))
                }
                for folder in folders where FileManager.default.fileExists(atPath: folder.path) {
                    do { try FileManager.default.trashItem(at: folder, resultingItemURL: nil) }
                    catch { result += " Could not trash \(folder.path): \(error.localizedDescription)" }
                }
            }
            do { try FileManager.default.trashItem(at: copy.app, resultingItemURL: nil); result += " Moved the app to the Trash." }
            catch { result += " Move the app to the Trash manually: \(error.localizedDescription)" }
            let message = result
            await MainActor.run {
                self.busy = false; self.report = message
                if quit {
                    if removeData, let id = Bundle.main.bundleIdentifier { UserDefaults.standard.removePersistentDomain(forName: id) }
                    NSApp.terminate(nil)
                } else { self.refresh() }
                AVSpeechSynthesisProviderVoice.updateSpeechVoices()
            }
        }
    }
    var thisCopy: Copy { Copy(app: Self.current, extensions: Self.extensions(in: Self.current)) }
}

struct VoiceInstallationView: View {
    @StateObject private var model = VoiceInstallations()
    @Environment(\.dismiss) private var dismiss
    @State private var selected: VoiceInstallations.Copy?
    @State private var uninstall = false
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("macOS combines voices from every registered speech app. This page manages copies with this app’s exact voice identifiers. Other speech apps remain separate.")
                    if model.busy { ProgressView("Checking voice installations") }
                    else if model.copies.isEmpty { Text("No other registered copies found.") }
                    ForEach(model.copies) { copy in
                        VStack(alignment: .leading) {
                            Text(copy.app.deletingPathExtension().lastPathComponent)
                            Text(copy.app.path).font(.caption).textSelection(.enabled)
                            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([copy.app]) }
                            Button("Remove this copy…", role: .destructive) { selected = copy }
                        }
                    }
                    Button("Check again") { model.refresh() }.disabled(model.busy)
                } header: { Text("Other registered copies") }
                Section {
                    Button("Uninstall this app…", role: .destructive) { uninstall = true }.disabled(model.busy)
                } footer: { Text("Unregisters this copy’s voices, moves the app to the Trash and quits. You choose whether to keep imported data.") }
                if let report = model.report { Text(report).textSelection(.enabled) }
            }
            .formStyle(.grouped)
            .navigationTitle("Voice installations")
            .toolbar { Button("Done") { dismiss() } }
            .task { model.refresh() }
            .confirmationDialog("Remove this registered copy? Imported data is kept.", isPresented: Binding(get: { selected != nil }, set: { if !$0 { selected = nil } })) {
                if let selected { Button("Unregister and Move to Trash", role: .destructive) { model.remove(selected); self.selected = nil } }
                Button("Cancel", role: .cancel) { selected = nil }
            } message: { Text(selected?.app.path ?? "") }
            .confirmationDialog("Uninstall this copy and quit? Removing imported data also affects other copies using this app’s data container.", isPresented: $uninstall) {
                Button("Uninstall and Keep Imported Data", role: .destructive) { model.remove(model.thisCopy, quit: true) }
                Button("Uninstall and Remove Imported Data", role: .destructive) { model.remove(model.thisCopy, quit: true, removeData: true) }
                Button("Cancel", role: .cancel) {}
            }
        }
        .frame(minWidth: 600, minHeight: 450)
    }
}
