import SwiftUI
import UniformTypeIdentifiers

@main
struct BrawTranscoderApp: App {
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
        guard let brawType = UTType(filenameExtension: "braw") else { return }
        panel.allowedContentTypes = [brawType]
        panel.allowsMultipleSelection = true
        if panel.runModal() == .OK {
            for url in panel.urls {
                _ = project.importClip(path: url.path)
            }
        }
    }
}
