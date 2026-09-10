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
        XCTAssertTrue(app.buttons["apple-sign-in-button"].exists)
        XCTAssertTrue(app.buttons["google-sign-in-button"].exists)
        XCTAssertTrue(app.buttons["create-account-button"].exists)
        XCTAssertFalse(app.switches["newsletter-consent-checkbox"].exists)
    }

    @MainActor
    func testRegistrationScreenShowsOptionalNewsletterConsentAndProviderSignup() throws {
        let app = XCUIApplication()
        app.launchArguments.append("--uitesting-reset")
        app.launch()

        XCTAssertTrue(app.buttons["create-account-button"].waitForExistence(timeout: 20))
        app.buttons["create-account-button"].tap()

        XCTAssertTrue(app.switches["newsletter-consent-checkbox"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.switches["newsletter-consent-checkbox"].isSelected)
        XCTAssertTrue(app.buttons["apple-register-button"].exists)
        XCTAssertTrue(app.buttons["google-register-button"].exists)
    }

    @MainActor
    func testForgotPasswordOpensResetRequestScreen() throws {
        let app = XCUIApplication()
        app.launchArguments.append("--uitesting-reset")
        app.launch()

        XCTAssertTrue(app.buttons["Forgot password?"].waitForExistence(timeout: 20))
        app.buttons["Forgot password?"].tap()
        XCTAssertTrue(app.scrollViews["forgot-password-screen"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["forgot-password-send-button"].exists)
    }

    @MainActor
    func testThemeSelectorShowsThreeModesAndPersistsSelection() throws {
        let app = XCUIApplication()
        app.launchArguments.append("--uitesting-reset")
        app.launchEnvironment["UITEST_FORCE_SETTINGS"] = "1"
        app.launch()

        let systemButton = app.buttons["theme-system-button"]
        let lightButton = app.buttons["theme-light-button"]
        let darkButton = app.buttons["theme-dark-button"]

        XCTAssertTrue(app.descendants(matching: .any)["theme-section"].waitForExistence(timeout: 10))
        XCTAssertTrue(systemButton.waitForExistence(timeout: 10))
        XCTAssertTrue(lightButton.exists)
        XCTAssertTrue(darkButton.exists)
        XCTAssertTrue(systemButton.isSelected)

        darkButton.tap()
        XCTAssertTrue(darkButton.isSelected)
        XCTAssertFalse(systemButton.isSelected)

        app.terminate()
        app.launchArguments.removeAll()
        app.launch()

        XCTAssertTrue(app.buttons["theme-dark-button"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["theme-dark-button"].isSelected)
    }

    @MainActor
    func testLaunchPerformance() throws {
        // This measures how long it takes to launch your application.
        measure(metrics: [XCTApplicationLaunchMetric()]) {
            XCUIApplication().launch()
        }
    }
}
