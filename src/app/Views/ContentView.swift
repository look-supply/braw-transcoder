import SwiftUI

struct ContentView: View {
    @ObservedObject var project: ProjectModel
    
    var body: some View {
        HSplitView {
            SidebarView(project: project)
                .frame(minWidth: 250, idealWidth: 250, maxWidth: 350)
                .layoutPriority(1)
            
            VSplitView {
                PreviewView(project: project)
                    .frame(minWidth: 400, minHeight: 300)
                
                ExportView(project: project)
                    .frame(minHeight: 130)
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
