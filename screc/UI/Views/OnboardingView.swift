import SwiftUI

struct OnboardingView: View {
    @ObservedObject var permissions: PermissionManager
    var onFinish: () -> Void

    var body: some View {
        VStack(spacing: 20) {
            header
            permissionCard
            howItWorks
            footer
        }
        .padding(28)
        .padding(.top, 8) // room for the floating traffic lights
        .frame(width: 460)
        .background(VisualEffectBackground(material: .sidebar).ignoresSafeArea())
    }

    private var header: some View {
        VStack(spacing: 6) {
            HStack(alignment: .lastTextBaseline, spacing: 10) {
                Text("●")
                    .font(.system(size: 26))
                    .foregroundStyle(.red)
                Text("screc")
                    .font(.system(size: 34, weight: .heavy, design: .rounded))
                    .foregroundStyle(.primary)
            }
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
                    Image(systemName: permissions.granted
                          ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                        .foregroundStyle(permissions.granted ? .green : .orange)
                    Text("Screen Recording Access")
                        .font(.headline)
                    Spacer()
                }
                if permissions.granted {
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
    }

    private var howItWorks: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("**Right-click** the red dot to start/stop recording",
                  systemImage: "cursorarrow.click")
            Label("**Left-click** for the menu — modes, recent recordings, settings",
                  systemImage: "contextualmenu.and.cursorarrow")
            Label("Recordings are compressed on the fly — share-ready when you stop",
                  systemImage: "bolt.fill")
        }
        .font(.callout)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var footer: some View {
        HStack {
            Button("Skip for Now") { onFinish() }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            Spacer()
            Button("Start Using screc") { onFinish() }
                .buttonStyle(.borderedProminent)
                .disabled(!permissions.granted)
        }
    }
}
