//
//  libreguard_vpn_iosUITests.swift
//  libreguard-vpn-iosUITests
//
//  Created by Marko Mihajlovic on 20. 6. 2026..
//

import XCTest

final class libreguard_vpn_iosUITests: XCTestCase {

    override func setUpWithError() throws {
        // Put setup code here. This method is called before the invocation of each test method in the class.

        // In UI tests it is usually best to stop immediately when a failure occurs.
        continueAfterFailure = false

        // In UI tests it’s important to set the initial state - such as interface orientation - required for your tests before they run. The setUp method is a good place to do this.
    }

    override func tearDownWithError() throws {
        // Put teardown code here. This method is called after the invocation of each test method in the class.
    }

    @MainActor
    func testLoginScreenPresentsBackendActions() throws {
        let app = XCUIApplication()
        app.launchArguments.append("--uitesting-reset")
        app.launchEnvironment["UITEST_FORCE_LOGIN"] = "1"
        app.launch()

        XCTAssertTrue(app.scrollViews["login-screen"].waitForExistence(timeout: 20))
        XCTAssertTrue(app.buttons["login-sign-in-button"].waitForExistence(timeout: 20))
        XCTAssertTrue(app.buttons["google-sign-in-button"].exists)
        XCTAssertTrue(app.buttons["create-account-button"].exists)
    }

    @MainActor
    func testLaunchPerformance() throws {
        // This measures how long it takes to launch your application.
        measure(metrics: [XCTApplicationLaunchMetric()]) {
            XCUIApplication().launch()
        }
    }
}
