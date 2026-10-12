//
//  libreguard_vpn_iosApp.swift
//  libreguard-vpn-ios
//
//  Created by Marko Mihajlovic on 20. 6. 2026..
//

import SwiftUI
import SwiftData

@main
struct libreguard_vpn_iosApp: App {
    private let modelContainer: ModelContainer

    init() {
        let container = try! ModelContainer(for: LocalConnectionRecord.self)
        self.modelContainer = container
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--uitesting-reset") {
            UserDefaults.standard.removeObject(forKey: DataUseDisclosure.acceptanceKey)
        }
        #endif
    }

    var body: some Scene {
        WindowGroup {
            DataUseDisclosureGate(modelContainer: modelContainer)
        }
        .modelContainer(modelContainer)
    }
}
