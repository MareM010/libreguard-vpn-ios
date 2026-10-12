import SwiftUI
import SwiftData

nonisolated enum DataUseDisclosure {
    static let currentVersion = 1
    static let acceptanceKey = "privacy.dataUse.acceptedVersion"
}

/// The service model is constructed only after the notice is acknowledged.
/// This also prevents restored sessions, purchase listeners, and latency
/// requests from running behind a first-launch consent overlay.
struct DataUseDisclosureGate: View {
    let modelContainer: ModelContainer
    @AppStorage(DataUseDisclosure.acceptanceKey) private var acceptedVersion = 0
    @State private var pendingURL: URL?

    var body: some View {
        Group {
            if acceptedVersion == DataUseDisclosure.currentVersion {
                DisclosedAppContent(modelContainer: modelContainer, initialURL: pendingURL)
            } else {
                DataUseDisclosureView {
                    acceptedVersion = DataUseDisclosure.currentVersion
                }
            }
        }
        .onOpenURL { url in
            if acceptedVersion != DataUseDisclosure.currentVersion { pendingURL = url }
        }
    }
}

private struct DisclosedAppContent: View {
    @StateObject private var appModel: AppModel
    let initialURL: URL?

    init(modelContainer: ModelContainer, initialURL: URL?) {
        self.initialURL = initialURL
        _appModel = StateObject(wrappedValue: AppModel(
            statisticsRecorder: SwiftDataStatisticsRecorder(context: modelContainer.mainContext)
        ))
    }

    var body: some View {
        ContentView(initialURL: initialURL).environmentObject(appModel)
    }
}

struct DataUseDisclosureView: View {
    let onContinue: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                Image("LibreGuardLogo").resizable().scaledToFit().frame(width: 64, height: 64)
                Text("Your data and LibreGuard")
                    .font(.largeTitle.bold())
                Text("Before you create an account, sign in, buy Pro, or connect, here is how the service uses your information.")
                    .foregroundStyle(.secondary)
                disclosure("Account and device information", "Account details, credentials, and device identifiers are processed to sign you in, secure your access, and enforce device limits.")
                disclosure("Purchases and VPN usage", "Subscription and purchase information, aggregate byte totals, and connection and security events are processed to provide service, enforce plan limits, handle billing, and troubleshoot access. Your traffic passes through VPN servers while connected.")
                disclosure("Apple, Google, and your choices", "Apple or Google processes the sign-in method you choose. Apple processes in-app purchases. Newsletter signup is optional, and its consent preference is stored separately. App settings and local connection statistics are stored on your device.")
                Text("Read the policies for retention, deletion, and third-party handling. Acknowledging this notice does not sign you up for a newsletter or grant advertising permission.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                HStack(spacing: 24) {
                    Link("Privacy Policy", destination: URL(string: "https://libreguard.net/Privacy")!)
                    Link("Terms of Service", destination: URL(string: "https://libreguard.net/Terms")!)
                }
                .font(.subheadline.weight(.semibold))
                Button("Continue") { onContinue() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .frame(maxWidth: .infinity)
                    .accessibilityIdentifier("data-use-continue-button")
            }
            .padding(28)
            .frame(maxWidth: 620, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .accessibilityIdentifier("data-use-disclosure-screen")
    }

    private func disclosure(_ title: String, _ description: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.headline)
            Text(description).font(.body).foregroundStyle(.secondary)
        }
    }
}

struct OpenSourceLicensesView: View {
    private static let documents = [
        "THIRD_PARTY_NOTICES", "LICENSE", "APP_STORE_PERMISSION", "TunnelKit-LICENSE",
        "OpenSSL-LICENSE", "AppAuth-LICENSE", "swift-asn1-LICENSE",
        "swift-certificates-LICENSE", "swift-crypto-LICENSE", "swift-log-LICENSE", "MPL-2.0"
    ]

    var body: some View {
        List(Self.documents, id: \.self) { name in
            NavigationLink(name.replacingOccurrences(of: "_", with: " ")) {
                ScrollView {
                    Text(contents(name)).font(.system(.footnote, design: .monospaced))
                        .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding()
                }
                .navigationTitle(name).navigationBarTitleDisplayMode(.inline)
            }
        }
        .navigationTitle("Open Source Licenses")
    }

    private func contents(_ name: String) -> String {
        guard let url = Bundle.main.url(forResource: name, withExtension: "txt"),
              let text = try? String(contentsOf: url, encoding: .utf8) else {
            return "The license document could not be loaded."
        }
        return text
    }
}
