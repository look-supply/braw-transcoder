import SwiftUI

enum PanelLayout {
    static let headerHeight: CGFloat = 40
}

struct ContentView: View {
    @ObservedObject var project: ProjectModel
    
    var body: some View {
        HSplitView {
            SidebarView(project: project)
                .frame(minWidth: 250, idealWidth: 250, maxWidth: 350)
                .layoutPriority(1)
            
            VStack(spacing: 0) {
                PreviewView(project: project)
                    .frame(minWidth: 400, minHeight: 300)
                    .frame(maxHeight: .infinity)
                Divider()
                ExportView(project: project)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .layoutPriority(2)
            
            InspectorView(project: project)
                .frame(minWidth: 250, idealWidth: 250, maxWidth: 350)
                .layoutPriority(1)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .alert("Import failed", isPresented: Binding(
            get: { project.importError != nil },
            set: { if !$0 { project.importError = nil } }
        )) {
            Button("OK") { project.importError = nil }
        } message: {
            Text(project.importError ?? "")
        }
    }
}
