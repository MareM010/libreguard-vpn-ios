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
    @StateObject private var appModel: AppModel

    init() {
        let container = try! ModelContainer(for: LocalConnectionRecord.self)
        self.modelContainer = container
        _appModel = StateObject(
            wrappedValue: AppModel(
                statisticsRecorder: SwiftDataStatisticsRecorder(context: container.mainContext)
            )
        )
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(appModel)
        }
        .modelContainer(modelContainer)
    }
}
