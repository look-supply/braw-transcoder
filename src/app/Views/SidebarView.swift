import SwiftUI
import UniformTypeIdentifiers

struct SidebarView: View {
    @ObservedObject var project: ProjectModel
    @State private var selectedIndices: Set<Int> = []
    @State private var keyMonitor: Any?
    @State private var isDropTargeted = false
    
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
                    .disabled((project.isExporting || project.isImporting))
                }
                Button(action: importFiles) {
                    Image(systemName: "plus")
                }.help("Import BRAW files")
                .disabled((project.isExporting || project.isImporting))
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
                                    guard !(project.isExporting || project.isImporting) else { return }
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
            .overlay {
                if project.clipCount == 0 {
                    VStack(spacing: 8) {
                        Image(systemName: "tray.and.arrow.down")
                            .font(.title2)
                        Text("Drop BRAW files here")
                        Text("or use + to import")
                            .font(.caption)
                    }
                    .foregroundStyle(.secondary)
                    .allowsHitTesting(false)
                }
            }
            .background(
                Group {
                    Button("") { copyActiveClipSettings() }
                        .keyboardShortcut("c", modifiers: .command)
                    Button("") { pasteToSelectedClips() }
                        .keyboardShortcut("v", modifiers: .command)
                }
                .opacity(0)
                .frame(width: 1, height: 1)
            )
        }
        .contentShape(Rectangle())
        .dropDestination(for: URL.self) { urls, _ in
            importURLs(urls)
        } isTargeted: { targeted in
            isDropTargeted = targeted
        }
        .overlay {
            if isDropTargeted && !project.isExporting && !project.isImporting {
                Rectangle()
                    .strokeBorder(Color.accentColor, lineWidth: 2)
                    .background(Color.accentColor.opacity(0.08))
                    .allowsHitTesting(false)
            }
        }
        .onAppear {
            keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                if event.keyCode == 51 || event.keyCode == 117 {
                    deleteSelectedClips()
                    return nil
                }
                return event
            }
        }
        .onDisappear {
            if let monitor = keyMonitor {
                NSEvent.removeMonitor(monitor)
            }
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
            _ = importURLs(panel.urls)
        }
    }

    @discardableResult
    func importURLs(_ urls: [URL]) -> Bool {
        guard !project.isExporting, !project.isImporting else { return false }
        let clips = urls.filter { $0.isFileURL && $0.pathExtension.lowercased() == "braw" }
        guard !clips.isEmpty else { return false }
        for url in clips {
            _ = project.importClip(path: url.path)
        }
        return true
    }
    
    var multiSelectedIndices: [Int] {
        selectedIndices.sorted()
    }
    
    func deleteSelectedClips() {
        guard !(project.isExporting || project.isImporting), !selectedIndices.isEmpty else { return }
        let sorted = selectedIndices.sorted(by: >)
        for idx in sorted {
            project.removeClip(at: idx)
        }
        selectedIndices.removeAll()
    }
    
    func copyActiveClipSettings() {
        guard !(project.isExporting || project.isImporting) else { return }
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
        guard !(project.isExporting || project.isImporting), !selectedIndices.isEmpty else { return }
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

    private var thumbnailAspectRatio: CGFloat {
        guard clip.nativeWidth > 0, clip.nativeHeight > 0 else { return 16.0 / 9.0 }
        return CGFloat(clip.nativeWidth) / CGFloat(clip.nativeHeight)
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            // Filename above thumbnail
            Text(clip.fileName)
                .font(.system(size: 11, weight: .semibold))
                .lineLimit(1)
                .truncationMode(.middle)
                .foregroundColor(isActive ? .accentColor : .primary)
            
            // Thumbnail
            // Size the container before adding its content. An image or loading
            // indicator must not change the row's width-to-height ratio.
            RoundedRectangle(cornerRadius: 5)
                .fill(isActive
                    ? Color.accentColor.opacity(0.12)
                    : Color.black.opacity(0.22))
                .aspectRatio(thumbnailAspectRatio, contentMode: .fit)
                .overlay {
                    if let thumb = clip.thumbnail {
                        Image(nsImage: thumb)
                            .resizable()
                            .aspectRatio(thumbnailAspectRatio, contentMode: .fit)
                    } else {
                        VStack(spacing: 4) {
                            ProgressView().scaleEffect(0.7)
                            Text("Loading...")
                                .font(.system(size: 9))
                                .foregroundColor(.secondary)
                        }
                    }
                }
                .overlay {
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
                .clipShape(RoundedRectangle(cornerRadius: 5))
                .overlay {
                    RoundedRectangle(cornerRadius: 5)
                        .strokeBorder(isActive ? Color.accentColor : isSelected ? Color.secondary : Color.clear, lineWidth: 2)
                }
            
            // Metadata
            Text("\(clip.nativeWidth)×\(clip.nativeHeight)  \(String(format: "%.1f", clip.frameRate))fps  \(clip.frameCount)f")
                .font(.system(size: 9))
                .foregroundColor(.secondary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(isActive ? Color.accentColor.opacity(0.06) : Color.clear)
    }
}
