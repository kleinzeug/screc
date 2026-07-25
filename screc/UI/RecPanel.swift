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
        let size = hostingView.fittingSize
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
        panel.sharingType = .none
        panel.isReleasedWhenClosed = false
        return panel
    }

    /// Below the target rect, clamped to the screen; inside it if no room.
    static func position(_ panel: NSPanel, below globalRect: NSRect, on screen: NSScreen) {
        let size = panel.frame.size
        var origin = NSPoint(x: globalRect.midX - size.width / 2,
                             y: globalRect.minY - size.height - 12)
        if origin.y < screen.visibleFrame.minY {
            origin.y = globalRect.minY + 12
        }
        origin.x = min(max(origin.x, screen.visibleFrame.minX + 8),
                       screen.visibleFrame.maxX - size.width - 8)
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
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.regularMaterial, in: Capsule())
    }
}
