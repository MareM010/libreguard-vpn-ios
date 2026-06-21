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
    @StateObject private var appModel = AppModel()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(appModel)
        }
        .modelContainer(for: LocalConnectionRecord.self)
    }
}
