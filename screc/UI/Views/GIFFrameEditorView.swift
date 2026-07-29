import SwiftUI

/// Thumbnail-strip GIF frame editor: click frames to mark them for removal,
/// Save rewrites the file in place (delays and loop preserved).
struct GIFFrameEditorView: View {
    let document: GIFDocument
    var onSaved: (URL) -> Void
    var onClose: () -> Void

    @State private var removed: Set<Int> = []
    @State private var saving = false
    @State private var errorText: String?

    private let columns = [GridItem(.adaptive(minimum: 116), spacing: 10)]

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                LazyVGrid(columns: columns, spacing: 10) {
                    ForEach(document.frames) { frame in
                        frameCell(frame)
                    }
                }
                .padding(12)
            }

            Divider()

            HStack(spacing: 12) {
                Button("Reveal in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([document.url])
                }
                Text("\(document.frames.count - removed.count) of \(document.frames.count) frames kept")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                if let errorText {
                    Text(errorText)
                        .font(.callout)
                        .foregroundStyle(.red)
                }
                Spacer()
                Button("Cancel") { onClose() }
                Button(removed.isEmpty ? "Save" : "Save (removes \(removed.count))") {
                    save()
                }
                .buttonStyle(.borderedProminent)
                .disabled(saving || removed.isEmpty || removed.count == document.frames.count)
            }
            .padding(12)
        }
        .frame(minWidth: 540, minHeight: 400)
    }

    private func frameCell(_ frame: GIFDocument.Frame) -> some View {
        let isRemoved = removed.contains(frame.id)
        return VStack(spacing: 4) {
            Image(decorative: frame.thumbnail, scale: 1)
                .resizable()
                .scaledToFit()
                .frame(maxWidth: .infinity)
                .overlay {
                    if isRemoved {
                        ZStack {
                            Color.black.opacity(0.55)
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 22))
                                .foregroundStyle(.white, .red)
                        }
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6)
                    .stroke(Color.primary.opacity(0.15), lineWidth: 1))
            Text("#\(frame.id + 1)")
                .font(.caption2)
                .foregroundStyle(isRemoved ? .tertiary : .secondary)
        }
        .contentShape(Rectangle())
        .onTapGesture {
            if isRemoved {
                removed.remove(frame.id)
            } else {
                removed.insert(frame.id)
            }
        }
        .help(isRemoved ? "Click to keep this frame" : "Click to remove this frame")
    }

    private func save() {
        saving = true
        errorText = nil
        let kept = document.frames.map(\.id).filter { !removed.contains($0) }
        let url = document.url
        Task {
            do {
                // Rewriting decodes every kept frame — keep it off the main
                // thread so the window stays responsive.
                try await Task.detached(priority: .userInitiated) {
                    try GIFDocument.save(url: url, keptIndices: kept)
                }.value
                onSaved(url)
                onClose()
            } catch {
                errorText = error.localizedDescription
                saving = false
            }
        }
    }
}
