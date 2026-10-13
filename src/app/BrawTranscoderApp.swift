import SwiftUI
import UniformTypeIdentifiers

@main
struct BrawTranscoderApp: App {
    init() {
        NSWindow.allowsAutomaticWindowTabbing = false
    }
    
    @StateObject private var project = ProjectModel()
    @State private var isSavingEmbeddedLUT = false
    
    var body: some Scene {
        Window("BRAW Transcoder", id: "main") {
            ContentView(project: project)
                .frame(minWidth: 1000, minHeight: 700)
        }
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(after: .newItem) {
                Button("Import BRAW...") {
                    openFilePicker()
                }
                .keyboardShortcut("o", modifiers: .command)
                Button("Save Embedded LUT…") {
                    saveEmbeddedLUT()
                }
                .disabled(project.selectedClip?.hasEmbeddedLUT != true || isSavingEmbeddedLUT || project.isExporting || project.isImporting)
            }
        }
    }
    func saveEmbeddedLUT() {
        guard let clip = project.selectedClip, clip.hasEmbeddedLUT, !isSavingEmbeddedLUT else { return }
        let panel = NSSavePanel()
        panel.title = "Save Embedded LUT"
        panel.allowedContentTypes = [UTType(filenameExtension: "cube") ?? .data]
        panel.canCreateDirectories = true
        let name = clip.embeddedLUTName.isEmpty ? clip.fileName : clip.embeddedLUTName
        let stem = URL(fileURLWithPath: name).deletingPathExtension().lastPathComponent
        panel.nameFieldStringValue = "\(stem).cube"
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        isSavingEmbeddedLUT = true
        Task { @MainActor in
            defer { isSavingEmbeddedLUT = false }
            if let error = await clip.saveEmbeddedLUT(to: destination) {
                let alert = NSAlert()
                alert.messageText = "Could Not Save Embedded LUT"
                alert.informativeText = error
                alert.alertStyle = .warning
                alert.runModal()
            }
        }
    }
    
    func openFilePicker() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        // Use allowedContentTypes if available, otherwise fall back to extension check
        if let brawType = UTType(filenameExtension: "braw") {
            panel.allowedContentTypes = [brawType, UTType.data].compactMap { $0 }
        }
        if panel.runModal() == .OK {
            for url in panel.urls {
                if url.pathExtension.lowercased() == "braw" {
                    _ = project.importClip(path: url.path)
                }
            }
        }
    }
}
