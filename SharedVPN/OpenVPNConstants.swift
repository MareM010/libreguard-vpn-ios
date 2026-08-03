import Foundation

enum OpenVPNConstants {
    nonisolated static let tunnelBundleIdentifier = "net.libreguard.libreguard-vpn-ios.openvpn-tunnel"
    nonisolated static let appGroupIdentifier = "group.net.libreguard.libreguard-vpn-ios"

    /// Returns the bundle identifier of the packet-tunnel extension embedded in
    /// the installed app. This avoids saving a provider identifier that has
    /// drifted from the identifier in the signed .appex.
    static func embeddedTunnelBundleIdentifier(in bundle: Bundle = .main) -> String? {
        guard let pluginsURL = bundle.builtInPlugInsURL,
              let pluginURLs = try? FileManager.default.contentsOfDirectory(
                  at: pluginsURL,
                  includingPropertiesForKeys: nil,
                  options: [.skipsHiddenFiles]
              ) else {
            return nil
        }

        return pluginURLs
            .filter { $0.pathExtension == "appex" }
            .compactMap { Bundle(url: $0) }
            .first {
                let extensionInfo = $0.object(forInfoDictionaryKey: "NSExtension") as? [String: Any]
                return extensionInfo?["NSExtensionPointIdentifier"] as? String
                    == "com.apple.networkextension.packet-tunnel"
            }?
            .bundleIdentifier
    }
}
