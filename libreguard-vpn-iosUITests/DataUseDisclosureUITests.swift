import XCTest

extension XCUIApplication {
    @MainActor func launchAcceptingDataUse() {
        launch()
        let button = buttons["data-use-continue-button"]
        if button.waitForExistence(timeout: 5) {
            let screen = scrollViews["data-use-disclosure-screen"]
            for _ in 0..<4 where !button.isHittable { screen.swipeUp() }
            button.tap()
        }
    }
}

final class DataUseDisclosureUITests: XCTestCase {
    @MainActor func testOfflineLicenseDocumentsOpenFromSettings() {
        let app = XCUIApplication()
        app.launchArguments.append("--uitesting-reset")
        app.launchEnvironment["UITEST_FORCE_SETTINGS"] = "1"
        app.launchAcceptingDataUse()
        let licenses = app.buttons["Open Source Licenses"]
        XCTAssertTrue(app.scrollViews["settings-compact-list"].waitForExistence(timeout: 15))
        for _ in 0..<5 where !licenses.isHittable { app.scrollViews["settings-compact-list"].swipeUp() }
        XCTAssertTrue(licenses.waitForExistence(timeout: 5))
        licenses.tap()
        let license = app.buttons["LICENSE"]
        XCTAssertTrue(license.waitForExistence(timeout: 5))
        license.tap()
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "GNU GENERAL PUBLIC LICENSE")).firstMatch.waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["The license document could not be loaded."].exists)
    }

    @MainActor func testNoticeBlocksLoginAndPurchaseUntilAcknowledged() {
        let app = XCUIApplication()
        app.launchArguments.append("--uitesting-reset")
        app.launch()
        XCTAssertTrue(app.scrollViews["data-use-disclosure-screen"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["login-sign-in-button"].exists)
        XCTAssertFalse(app.buttons["apple-sign-in-button"].exists)
        XCTAssertFalse(app.staticTexts["Upgrade to Pro"].exists)
        let button = app.buttons["data-use-continue-button"]
        for _ in 0..<4 where !button.isHittable { app.scrollViews["data-use-disclosure-screen"].swipeUp() }
        button.tap()
        XCTAssertTrue(app.buttons["login-sign-in-button"].waitForExistence(timeout: 15))
        app.terminate()
        app.launchArguments = []
        app.launch()
        XCTAssertFalse(app.scrollViews["data-use-disclosure-screen"].exists)
        XCTAssertTrue(app.buttons["login-sign-in-button"].waitForExistence(timeout: 15))
    }
}
