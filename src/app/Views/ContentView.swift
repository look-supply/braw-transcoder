import SwiftUI

struct ContentView: View {
    @ObservedObject var project: ProjectModel
    
    var body: some View {
        HSplitView {
            SidebarView(project: project)
                .frame(minWidth: 200, maxWidth: 350)
                .layoutPriority(1)
            
            VSplitView {
                PreviewView(project: project)
                    .frame(minWidth: 400, minHeight: 300)
                
                ExportView(project: project)
                    .frame(minHeight: 130)
            }
            .layoutPriority(2)
            
            InspectorView(project: project)
                .frame(minWidth: 200, maxWidth: 350)
                .layoutPriority(1)
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }
}
