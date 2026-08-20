import AppKit
import SwiftUI

/// The floating, non-activating confirm pill shared by the region selector
/// and the window picker: cancel · size readout · red REC button. Clicking it
/// never steals focus from the app about to be recorded.
@MainActor
enum RecPanel {
    static func make(width: Int, height: Int,
                     onRecord: @escaping () -> Void,
                     onCancel: @escaping () -> Void) -> NSPanel {
        let content = RecPanelView(width: width, height: height,
                                   onRecord: onRecord, onCancel: onCancel)
        let hostingView = NSHostingView(rootView: content)
        var size = hostingView.fittingSize
        // fittingSize can under-measure the capsule's padding; give the
        // readout room rather than letting it truncate.
        size.width = max(size.width, hostingView.intrinsicContentSize.width) + 4
        let panel = NSPanel(contentRect: NSRect(origin: .zero, size: size),
                            styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.contentView = hostingView
        panel.isFloatingPanel = true
        panel.level = .screenSaver
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isReleasedWhenClosed = false
        return panel
    }

    /// Sits just below the target rect. When the rect reaches too close to
    /// the bottom of the screen, the bar moves *inside* it — hugging the
    /// inner edge of the same bottom border — instead of going off-screen.
    static func position(_ panel: NSPanel, below globalRect: NSRect, on screen: NSScreen) {
        let size = panel.frame.size
        let gap: CGFloat = 12
        var origin = NSPoint(x: globalRect.midX - size.width / 2,
                             y: globalRect.minY - size.height - gap)

        if origin.y < screen.frame.minY + 8 {
            let inside = globalRect.minY + gap
            // Only park inside if the rect is actually tall enough to hold it.
            origin.y = globalRect.height > size.height + 2 * gap
                ? inside
                : max(globalRect.maxY + gap, screen.frame.minY + 8)
        }
        origin.x = min(max(origin.x, screen.frame.minX + 8),
                       screen.frame.maxX - size.width - 8)
        origin.y = min(origin.y, screen.frame.maxY - size.height - 8)
        panel.setFrameOrigin(origin)
        panel.orderFrontRegardless()
    }
}

private struct RecPanelView: View {
    let width: Int
    let height: Int
    var onRecord: () -> Void
    var onCancel: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Button(action: onCancel) {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .semibold))
            }
            .buttonStyle(.bordered)
            .help("Cancel (Esc)")

            Text("\(width) × \(height)")
                .font(.system(.callout, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .fixedSize()

            Button(action: onRecord) {
                HStack(spacing: 5) {
                    Image(systemName: "record.circle.fill")
                    Text("REC").fontWeight(.bold)
                }
            }
            .buttonStyle(.borderedProminent)
            .tint(.red)
            .help("Start recording (Enter)")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .fixedSize()
        .background(.regularMaterial, in: Capsule())
    }
}
