import SwiftUI
import UniformTypeIdentifiers

@main
struct BrawTranscoderApp: App {
    init() {}
    
    @StateObject private var project = ProjectModel()
    
    var body: some Scene {
        WindowGroup {
            ContentView(project: project)
                .frame(minWidth: 1200, minHeight: 700)
        }
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(after: .newItem) {
                Button("Import BRAW...") {
                    openFilePicker()
                }
                .keyboardShortcut("o", modifiers: .command)
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
