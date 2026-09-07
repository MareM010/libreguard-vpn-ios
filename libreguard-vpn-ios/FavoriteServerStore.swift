import Foundation

@MainActor
protocol FavoriteServerStoring: AnyObject {
    func favoriteServerIDs(for userID: String) -> [Int]
    func saveFavoriteServerIDs(_ serverIDs: [Int], for userID: String)
}

@MainActor
final class UserDefaultsFavoriteServerStore: FavoriteServerStoring {
    private let defaults: UserDefaults
    private let keyPrefix = "vpn.favoriteServers."

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func favoriteServerIDs(for userID: String) -> [Int] {
        guard let stored = defaults.array(forKey: key(for: userID)) else { return [] }
        return stored.compactMap { ($0 as? NSNumber)?.intValue }
    }

    func saveFavoriteServerIDs(_ serverIDs: [Int], for userID: String) {
        let key = key(for: userID)
        if serverIDs.isEmpty {
            defaults.removeObject(forKey: key)
        } else {
            defaults.set(serverIDs, forKey: key)
        }
    }

    private func key(for userID: String) -> String {
        "\(keyPrefix)\(userID)"
    }
}
