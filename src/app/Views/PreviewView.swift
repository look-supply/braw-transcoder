import SwiftUI

struct PreviewView: View {
    @ObservedObject var project: ProjectModel
    
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                if let clip = project.selectedClip {
                    Text(clip.fileName)
                        .font(.system(size: 12, weight: .medium)).lineLimit(1)
                    Spacer()
                    Text("\(clip.nativeWidth)×\(clip.nativeHeight)")
                        .font(.system(size: 11)).foregroundColor(.secondary)
                    Text("·").foregroundColor(.secondary)
                    Text("\(String(format: "%.2f", clip.frameRate)) fps")
                        .font(.system(size: 11)).foregroundColor(.secondary)
                } else {
                    Text("No clip selected")
                        .font(.system(size: 12)).foregroundColor(.secondary)
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 6)
            .background(Color(nsColor: .controlBackgroundColor).opacity(0.5))
            
            Divider()
            
            if let clip = project.selectedClip {
                PreviewContent(clip: clip, isExporting: project.isExporting)
            } else {
                GeometryReader { geo in
                    ZStack {
                        Color.black.opacity(0.92)
                        VStack(spacing: 12) {
                            Image(systemName: "film.stack").font(.system(size: 56))
                                .foregroundColor(.white.opacity(0.15))
                            Text("No Clip Selected").font(.title3)
                                .foregroundColor(.white.opacity(0.35))
                            Text("Import a BRAW file or select a clip from the sidebar")
                                .font(.callout).foregroundColor(.white.opacity(0.2))
                        }
                    }
                }
            }
        }
    }
}

struct PreviewContent: View {
    @ObservedObject var clip: ClipModel
    let isExporting: Bool
    
    var body: some View {
        GeometryReader { geo in
            ZStack {
                Color.black.opacity(0.92)
                
                let aspect = clip.nativeHeight > 0
                    ? CGFloat(clip.nativeWidth) / CGFloat(clip.nativeHeight)
                    : 16.0 / 9.0
                
                if let preview = clip.preview {
                    Image(nsImage: preview)
                        .resizable()
                        .aspectRatio(aspect, contentMode: .fit)
                        .frame(maxWidth: geo.size.width - 24, maxHeight: geo.size.height - 60)
                } else if clip.isLoadingPreview {
                    ProgressView().scaleEffect(1.2)
                } else {
                    VStack(spacing: 12) {
                        Image(systemName: "film").font(.system(size: 48))
                            .foregroundColor(.white.opacity(0.25))
                        Text("\(clip.nativeWidth) × \(clip.nativeHeight)")
                            .font(.system(size: 16, weight: .semibold, design: .monospaced))
                            .foregroundColor(.white.opacity(0.6))
                    }
                }
                
                VStack {
                    if let error = clip.previewError {
                        Text(error).font(.caption).foregroundStyle(.white)
                            .padding(8).background(.black.opacity(0.8))
                    }
                    Spacer()
                    VStack(spacing: 4) {
                        HStack {
                            Text("Frame").font(.system(size: 10))
                                .foregroundColor(.white.opacity(0.5))
                            
                            Slider(value: Binding<Double>(
                                get: { Double(clip.currentFrame) },
                                set: { clip.currentFrame = UInt64($0) }
                            ), in: 0...Double(max(clip.frameCount, 1) - 1))
                            .controlSize(.small)
                            .disabled(isExporting)
                            
                            Text("\(clip.currentFrame)").font(.system(size: 10, design: .monospaced))
                                .foregroundColor(.white.opacity(0.7))
                                .frame(width: 60, alignment: .trailing)
                        }
                        .padding(.horizontal, 16)
                        
                        HStack {
                            Text("0").font(.system(size: 9, design: .monospaced))
                                .foregroundColor(.white.opacity(0.3))
                            Spacer()
                            Text("\(clip.frameCount - 1)").font(.system(size: 9, design: .monospaced))
                                .foregroundColor(.white.opacity(0.3))
                        }
                        .padding(.horizontal, 16)
                    }
                    .padding(.vertical, 10)
                    .background(Color.black.opacity(0.7))
                }
            }
        }
    }
}
