import Foundation

protocol VPNProtocolSelectionStoring: AnyObject {
    var selectedProtocol: VPNConfigurationProtocol { get set }
}

final class UserDefaultsVPNProtocolSelectionStore: VPNProtocolSelectionStoring {
    private let defaults: UserDefaults
    private let key = "vpn.protocol.selection"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var selectedProtocol: VPNConfigurationProtocol {
        get {
            guard let rawValue = defaults.string(forKey: key),
                  let selected = VPNConfigurationProtocol(rawValue: rawValue) else {
                return .ikev2
            }
            return selected
        }
        set {
            defaults.set(newValue.rawValue, forKey: key)
        }
    }
}

