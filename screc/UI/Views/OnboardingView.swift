import SwiftUI

struct OnboardingView: View {
    @ObservedObject var permissions: PermissionManager
    var onFinish: () -> Void

    /// The debug-mode button is deliberately hard to hit by accident:
    /// hover the permission card *and* hold ⌥. Debug builds only — the
    /// escape hatch is compiled out of anything shipped.
    @State private var hoveringPermissionCard = false
    @State private var optionHeld = false
    private var showsDebugToggle: Bool {
        #if DEBUG
        hoveringPermissionCard && optionHeld
        #else
        false
        #endif
    }

    var body: some View {
        VStack(spacing: 20) {
            header
            permissionCard
            howItWorks
            links
            footer
        }
        .padding(28)
        .padding(.top, 8) // room for the floating traffic lights
        .frame(width: 460)
        .background(VisualEffectBackground(material: .sidebar).ignoresSafeArea())
    }

    private var header: some View {
        VStack(spacing: 6) {
            Button {
                NSWorkspace.shared.open(BuildFlavor.siteURL)
            } label: {
                HStack(alignment: .lastTextBaseline, spacing: 10) {
                    Text("●")
                        .font(.system(size: 26))
                        .foregroundStyle(.red)
                    Text("screc")
                        .font(.system(size: 34, weight: .heavy, design: .rounded))
                        .foregroundStyle(.primary)
                }
            }
            .buttonStyle(.plain)
            .help("Open screc.app")
            Text("One click in the menu bar → a small, share-ready recording.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Text("Version \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—")")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }

    private var permissionCard: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Image(systemName: permissions.debugMode
                          ? "ladybug.fill"
                          : (permissions.granted
                             ? "checkmark.circle.fill" : "exclamationmark.circle.fill"))
                        .foregroundStyle(permissions.debugMode ? .purple
                                         : (permissions.granted ? .green : .orange))
                    Text("Screen Recording Access")
                        .font(.headline)
                    Spacer()
                    if showsDebugToggle || permissions.debugMode {
                        Button(permissions.debugMode ? "Leave Debug Mode" : "Debug Mode") {
                            permissions.setDebugMode(!permissions.debugMode)
                        }
                        .controlSize(.small)
                        .help("Pretend access was granted and record black frames — for testing the UI without re-granting permission after every rebuild")
                    }
                }
                if permissions.debugMode {
                    Text("""
                    **Debug mode** — screc behaves as if access were granted, but \
                    every recording is black frames. For development only.
                    """)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                } else if permissions.granted {
                    Text("Granted — screc can record your screen.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } else if !permissions.hasRequested {
                    Text("macOS requires your explicit permission before any app can record the screen.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Button("Allow Screen Recording…") {
                        permissions.requestAccess()
                    }
                    .buttonStyle(.borderedProminent)
                } else {
                    Text("""
                    Enable **screc** under System Settings → Privacy & Security → \
                    Screen & System Audio Recording, then relaunch. \
                    (macOS only applies the permission to a freshly launched app — \
                    the relaunch really is required, not a bug.)
                    """)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    HStack {
                        Button("Open System Settings") {
                            permissions.openSystemSettings()
                        }
                        Button("Relaunch screc") {
                            permissions.relaunch()
                        }
                        .buttonStyle(.borderedProminent)
                    }
                }
            }
            .padding(6)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onHover { hoveringPermissionCard = $0 }
        .onModifierKeysChanged(mask: .option) { _, new in
            optionHeld = new.contains(.option)
        }
    }

    private var howItWorks: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("**Right-click** the red dot to start/stop recording",
                  systemImage: "cursorarrow.click")
            Label("**Left-click** for the menu — modes, recent recordings, settings",
                  systemImage: "contextualmenu.and.cursorarrow")
            Label("Recordings are compressed on the fly — share-ready when you stop",
                  systemImage: "bolt.fill")
            Label("Hotkeys: **⌘⇧8** window · **⌘⇧9** screen · **⌘⇧0** stop — all rebindable in Settings",
                  systemImage: "keyboard")
        }
        .font(.callout)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var links: some View {
        if BuildFlavor.showsSourceLinks {
            HStack(spacing: 16) {
                Link("Source on GitHub", destination: BuildFlavor.repositoryURL)
                Text("·").foregroundStyle(.tertiary)
                Link("Buy me a coffee ☕", destination: BuildFlavor.coffeeURL)
            }
            .font(.callout)
        }
    }

    private var footer: some View {
        HStack {
            Button("Skip for Now") { onFinish() }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            Spacer()
            Button("Start Using screc") {
                // The calm moment for the notification prompt — not the
                // middle of the user's first save.
                Notifier.requestAuthorizationUpfront()
                onFinish()
            }
            .buttonStyle(.borderedProminent)
            .disabled(!permissions.granted)
        }
    }
}
