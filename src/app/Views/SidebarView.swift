import SwiftUI
import UniformTypeIdentifiers

struct SidebarView: View {
    @ObservedObject var project: ProjectModel
    @State private var selectedIndices: Set<Int> = []
    
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Assets").font(.headline).foregroundColor(.secondary)
                Spacer()
                if !selectedIndices.isEmpty {
                    Text("\(selectedIndices.count) selected")
                        .font(.system(size: 11)).foregroundColor(.accentColor)
                }
                if project.clipCount > 0 {
                    Button(action: { project.clearAllClips(); selectedIndices.removeAll() }) {
                        Image(systemName: "trash")
                    }.help("Clear all clips")
                    .disabled(project.isExporting)
                }
                Button(action: importFiles) {
                    Image(systemName: "plus")
                }.help("Import BRAW files")
                .disabled(project.isExporting)
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            
            Divider()
            
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(0..<project.clipCount, id: \.self) { index in
                        if let clip = project.getClip(at: index) {
                            let isSelected = selectedIndices.contains(index)
                            let isActive = index == project.selectedIndex
                            
                            ClipRowView(clip: clip, isActive: isActive, isSelected: isSelected)
                                .contentShape(Rectangle())
                                .onAppear { clip.loadThumbnail() }
                                .onTapGesture {
                                    guard !project.isExporting else { return }
                                    if NSEvent.modifierFlags.contains(.command) {
                                        if selectedIndices.contains(index) {
                                            selectedIndices.remove(index)
                                        } else {
                                            selectedIndices.insert(index)
                                        }
                                    } else {
                                        project.selectClip(index)
                                        selectedIndices = [index]
                                    }
                                }
                                .contextMenu {
                                    Button("Copy Settings") {
                                        project.copySettings(from: index)
                                    }
                                    
                                    Button("Paste Settings") {
                                        if selectedIndices.contains(index) {
                                            pasteToSelectedClips()
                                        } else {
                                            project.pasteSettings(to: index)
                                        }
                                    }
                                    
                                    Divider()
                                    
                                    Button("Remove", role: .destructive) {
                                        project.removeClip(at: index)
                                        selectedIndices.remove(index)
                                    }
                                }
                            
                            Divider().padding(.horizontal, 8)
                        }
                    }
                }
            }
            .background(
                Group {
                    Button("") { deleteSelectedClips() }
                        .keyboardShortcut(.delete, modifiers: [])
                    Button("") { copyActiveClipSettings() }
                        .keyboardShortcut("c", modifiers: .command)
                    Button("") { pasteToSelectedClips() }
                        .keyboardShortcut("v", modifiers: .command)
                }
                .opacity(0)
                .frame(width: 1, height: 1)
            )
        }
    }
    
    func importFiles() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
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
    
    var multiSelectedIndices: [Int] {
        selectedIndices.sorted()
    }
    
    func deleteSelectedClips() {
        guard !project.isExporting, !selectedIndices.isEmpty else { return }
        let sorted = selectedIndices.sorted(by: >)
        for idx in sorted {
            project.removeClip(at: idx)
        }
        selectedIndices.removeAll()
    }
    
    func copyActiveClipSettings() {
        guard !project.isExporting else { return }
        let sourceIndex: Int
        if selectedIndices.count == 1, let only = selectedIndices.first {
            sourceIndex = only
        } else {
            sourceIndex = project.selectedIndex
        }
        guard sourceIndex >= 0 else { return }
        project.copySettings(from: sourceIndex)
    }
    
    func pasteToSelectedClips() {
        guard !project.isExporting, !selectedIndices.isEmpty else { return }
        guard project.copiedSettings != nil else { return }
        for idx in selectedIndices {
            project.pasteSettings(to: idx)
        }
    }
}

struct ClipRowView: View {
    @ObservedObject var clip: ClipModel
    let isActive: Bool
    let isSelected: Bool
    
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            // Filename above thumbnail
            Text(clip.fileName)
                .font(.system(size: 11, weight: .semibold))
                .lineLimit(1)
                .truncationMode(.middle)
                .foregroundColor(isActive ? .accentColor : .primary)
            
            // Thumbnail
            ZStack {
                RoundedRectangle(cornerRadius: 5)
                    .fill(isActive
                        ? Color.accentColor.opacity(0.12)
                        : Color.black.opacity(0.22))
                    .frame(height: 90)
                    .overlay(
                        RoundedRectangle(cornerRadius: 5)
                            .stroke(isActive ? Color.accentColor : isSelected ? Color.secondary : Color.clear, lineWidth: 2)
                    )
                
                if let thumb = clip.thumbnail {
                    Image(nsImage: thumb)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(height: 90)
                        .clipShape(RoundedRectangle(cornerRadius: 5))
                } else {
                    VStack(spacing: 4) {
                        ProgressView().scaleEffect(0.7)
                        Text("Loading...")
                            .font(.system(size: 9))
                            .foregroundColor(.secondary)
                    }
                }
                
                // Selection checkmark
                if isSelected && !isActive {
                    VStack {
                        HStack {
                            Spacer()
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundColor(.accentColor)
                                .background(Circle().fill(Color.white).frame(width: 14, height: 14))
                                .font(.system(size: 16))
                                .padding(4)
                        }
                        Spacer()
                    }
                }
            }
            
            // Metadata
            Text("\(clip.nativeWidth)×\(clip.nativeHeight)  \(String(format: "%.1f", clip.frameRate))fps  \(clip.frameCount)f")
                .font(.system(size: 9))
                .foregroundColor(.secondary)
                .lineLimit(1)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(isActive ? Color.accentColor.opacity(0.06) : Color.clear)
    }
}
