
import Foundation
import XCTest
@testable import libreguard_vpn_ios

final class ApplePurchaseRecoveryProofTests: XCTestCase {
    func testPKCEUsesS256AndRandomIndependentState() throws {
        let first = try AppleRecoveryProof(), second = try AppleRecoveryProof()
        XCTAssertEqual(first.verifier.count, 43)
        XCTAssertEqual(first.challenge.count, 43)
        XCTAssertNotEqual(first.state, first.verifier)
        XCTAssertNotEqual(first.state, second.state)
        XCTAssertEqual(AppleRecoveryProof(state: "state", verifier: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk").challenge,
                       "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
    }
    func testCallbackRequiresExactStateDestinationAndNoExtraParameters() throws {
        let proof = try AppleRecoveryProof(), id = UUID()
        let scheme = "libreguard-ios-recovery"
        let valid = URL(string: "\(scheme)://complete?recoveryId=\(id.uuidString)&state=\(proof.state)")!
        XCTAssertNoThrow(try proof.validate(callback: valid, id: id, scheme: scheme))
        for invalid in [
            "\(scheme)://complete?recoveryId=\(id.uuidString)&state=wrong",
            "\(scheme)://complete?recoveryId=\(UUID().uuidString)&state=\(proof.state)",
            "\(scheme)://complete?recoveryId=\(id.uuidString)&state=\(proof.state)&token=anything",
            "\(scheme)://complete?recoveryId=\(id.uuidString)&state=\(proof.state)&state=\(proof.state)",
            "\(scheme)://other?recoveryId=\(id.uuidString)&state=\(proof.state)",
            "\(scheme)://complete/extra?recoveryId=\(id.uuidString)&state=\(proof.state)"
        ] { XCTAssertThrowsError(try proof.validate(callback: URL(string: invalid)!, id: id, scheme: scheme)) }
    }
    func testLaunchRequiresCanonicalManagementHostAndBoundedCapability() throws {
        let proof = try AppleRecoveryProof(), id = UUID()
        let path = "/Account/ApplePurchaseRecovery/\(id.uuidString)"
        let capability = String(repeating: "a", count: 43)
        let valid = AppleRecoveryStart(recoveryId: id, authorizationUrl: URL(string: "https://management.libreguard.net\(path)#launch=\(capability)")!, expiresAtUtc: Date().addingTimeInterval(600))
        XCTAssertNoThrow(try proof.validate(start: valid))
        for value in [
            "https://sandbox.management.libreguard.net\(path)#launch=\(capability)",
            "https://management.libreguard.net.evil.example\(path)#launch=\(capability)",
            "http://management.libreguard.net\(path)#launch=\(capability)",
            "https://management.libreguard.net\(path)?redirect=evil#launch=\(capability)",
            "https://management.libreguard.net\(path)#launch=short"
        ] {
            XCTAssertThrowsError(try proof.validate(start: AppleRecoveryStart(recoveryId: id, authorizationUrl: URL(string: value)!, expiresAtUtc: Date().addingTimeInterval(600))))
        }
    }
}
