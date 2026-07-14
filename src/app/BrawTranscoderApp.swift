import SwiftUI
import UniformTypeIdentifiers

@_silgen_name("braw_log_init_path") func _braw_log_init_path(_ path: UnsafePointer<CChar>)

@main
struct BrawTranscoderApp: App {
    init() {
        // Initialize memory trace log in the project directory
        if let cwd = FileManager.default.currentDirectoryPath as NSString? {
            // Walk up to find project root (look for CMakeLists.txt or .git)
            var dir = cwd as String
            if !FileManager.default.fileExists(atPath: dir + "/CMakeLists.txt") {
                // Try the user's documents path as fallback
                dir = NSHomeDirectory() + "/Documents/braw-to-mov"
            }
            _braw_log_init_path(dir)
        }
    }
    
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
