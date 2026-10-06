import XCTest
import Network

/// Opt in on a signed-in physical device by setting the test runner environment
/// LIBREGUARD_VPN_STRESS_NETWORK to wifi or cellular. Never resets the account,
/// changes network settings, or disables Kill Switch.
final class VPNProtocolStressTests: XCTestCase {
    @MainActor
    func testRapidCancellationAndReplacement() async throws {
        #if targetEnvironment(simulator)
        throw XCTSkip("Native cancellation requires a physical iPhone.")
        #else
        guard ProcessInfo.processInfo.environment["LIBREGUARD_VPN_STRESS_NETWORK"] == "wifi" else {
            throw XCTSkip("Opt in to the focused physical Wi-Fi cancellation check.")
        }
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launch()
        let control = app.buttons["vpn-connection-control"]
        XCTAssertTrue(control.waitForExistence(timeout: 30))
        defer {
            app.activate()
            if control.exists, control.label.hasPrefix("Protected.") || control.label.hasPrefix("Connecting.") {
                tapPrimaryAction(control)
            }
        }
        if control.label.hasPrefix("Protected.") || control.label.hasPrefix("Connecting.") {
            tapPrimaryAction(control)
            try waitForTerminal(control, in: app)
        }
        for protocolID in ["protocol-openvpn-button", "protocol-ikev2-ipsec-button", "protocol-openvpn-button"] {
            app.buttons["Servers"].tap()
            XCTAssertTrue(app.buttons[protocolID].waitForExistence(timeout: 10))
            app.buttons[protocolID].tap()
            app.buttons["Home"].tap()
            let primary = app.buttons["vpn-primary-action"]
            XCTAssertTrue(primary.waitForExistence(timeout: 10))
            // Do not wait for the connect animation or handshake before cancelling.
            primary.tap()
            primary.tap()
            let stopping = NSPredicate(format: "label BEGINSWITH %@ OR label BEGINSWITH %@", "Disconnecting.", "Not Protected.")
            XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: stopping, object: control)], timeout: 5), .completed)
            primary.tap()
            let connected = NSPredicate(format: "label BEGINSWITH %@", "Protected.")
            XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: connected, object: control)], timeout: 40), .completed,
                "Rapid replacement failed: \(app.alerts.firstMatch.debugDescription)")
            tapPrimaryAction(control)
            try waitForTerminal(control, in: app)
        }
        #endif
    }

    @MainActor
    func testFiftyProtocolSwitches() async throws {
        #if targetEnvironment(simulator)
        throw XCTSkip("Native VPN handoff requires a physical iPhone.")
        #else
        let network = ProcessInfo.processInfo.environment["LIBREGUARD_VPN_STRESS_NETWORK"] ?? ""
        guard ["wifi", "cellular"].contains(network) else {
            throw XCTSkip("Enable the physical-device VPN stress pass explicitly.")
        }
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launch()
        let control = app.buttons["vpn-connection-control"]
        XCTAssertTrue(control.waitForExistence(timeout: 30), "Sign into an account with OpenVPN access first.")
        addUIInterruptionMonitor(withDescription: "VPN setup approval") { alert in
            if alert.buttons["Allow"].exists { alert.buttons["Allow"].tap(); return true }
            return false
        }
        defer {
            app.activate()
            if control.exists, control.label.hasPrefix("Protected.") || control.label.hasPrefix("Connecting.") {
                tapPrimaryAction(control)
            }
        }
        if control.label.hasPrefix("Protected.") || control.label.hasPrefix("Connecting.") {
            tapPrimaryAction(control)
            try waitForTerminal(control, in: app)
        }
        let monitor = NWPathMonitor()
        monitor.start(queue: DispatchQueue(label: "VPNStressNetworkCheck"))
        try await Task.sleep(for: .seconds(1))
        let path = monitor.currentPath
        monitor.cancel()
        guard path.status == .satisfied,
              path.usesInterfaceType(network == "wifi" ? .wifi : .cellular) else {
            throw XCTSkip("The iPhone is not currently using the requested \(network) network.")
        }
        var request = URLRequest(url: URL(string: "https://management.libreguard.net")!)
        request.timeoutInterval = 8
        do { _ = try await URLSession.shared.data(for: request) }
        catch { throw XCTSkip("The requested \(network) network has no working internet connection.") }
        for index in 0..<50 {
            if control.label.hasPrefix("Protected.") || control.label.hasPrefix("Connecting.") {
                tapPrimaryAction(control)
                try waitForTerminal(control, in: app)
            }
            app.buttons["Servers"].tap()
            let protocolID = index.isMultiple(of: 2) ? "protocol-openvpn-button" : "protocol-ikev2-ipsec-button"
            let choice = app.buttons[protocolID]
            XCTAssertTrue(choice.waitForExistence(timeout: 10))
            choice.tap()
            app.buttons["Home"].tap()
            XCTAssertTrue(control.waitForExistence(timeout: 10))
            tapPrimaryAction(control)
            // Exercise cancellation and a queued replacement as well as clean switches.
            if index > 0, index.isMultiple(of: 5), control.label.hasPrefix("Connecting.") {
                tapPrimaryAction(control)
                tapPrimaryAction(control)
            }
            if index == 10 {
                XCUIDevice.shared.press(.home)
                app.activate()
            }
            let connected = NSPredicate(format: "label BEGINSWITH %@", "Protected.")
            let result = XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: connected, object: control)], timeout: 40)
            XCTAssertEqual(result, .completed, "Switch \(index + 1) on \(network) failed: \(app.alerts.firstMatch.debugDescription)")
            let attachment = XCTAttachment(string: "network=\(network) switch=\(index + 1) protocol=\(protocolID) connected")
            attachment.name = "VPN switch \(index + 1)"
            attachment.lifetime = .keepAlways
            add(attachment)
        }
        #endif
    }

    @MainActor
    private func tapPrimaryAction(_ control: XCUIElement) {
        let primary = XCUIApplication().buttons["vpn-primary-action"]
        XCTAssertTrue(primary.exists)
        let initial = control.label
        // The hero resizes during its connection animation. Confirm the tap
        // was delivered before attributing a missed moving target to VPN stop.
        for _ in 0..<3 {
            primary.tap()
            let changed = NSPredicate(format: "label != %@", initial)
            if XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: changed, object: control)], timeout: 2) == .completed {
                return
            }
        }
        XCTFail("The connection control did not accept the tap: \(control.debugDescription)")
    }

    @MainActor
    private func waitForTerminal(_ control: XCUIElement, in app: XCUIApplication) throws {
        if app.buttons["Keep VPN Connected"].exists {
            app.buttons["Keep VPN Connected"].tap()
            throw XCTSkip("Disable Kill Switch explicitly before testing protocol switches.")
        }
        let terminal = NSPredicate(format: "label BEGINSWITH %@ OR label BEGINSWITH %@", "Not Protected.", "VPN Unavailable.")
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: terminal, object: control)], timeout: 15), .completed)
    }
}
