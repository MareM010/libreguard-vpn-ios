import AuthenticationServices
import SwiftUI
import UIKit

/// Each native controller retains its originating operation, including failures.
struct CorrelatedAppleSignInButton: UIViewRepresentable {
    let type: ASAuthorizationAppleIDButton.ButtonType
    let style: ASAuthorizationAppleIDButton.Style
    @ObservedObject var app: AppModel

    func makeCoordinator() -> Coordinator { Coordinator(app: app) }

    func makeUIView(context: Context) -> ASAuthorizationAppleIDButton {
        let button = ASAuthorizationAppleIDButton(type: type, style: style)
        button.addTarget(context.coordinator, action: #selector(Coordinator.begin(_:)), for: .touchUpInside)
        return button
    }

    func updateUIView(_ button: ASAuthorizationAppleIDButton, context: Context) {
        button.isEnabled = !app.isAuthenticating
    }

    @MainActor
    final class Coordinator: NSObject {
        private let app: AppModel
        private var operations: [UUID: AppleAuthorizationOperation] = [:]

        init(app: AppModel) { self.app = app }

        @objc func begin(_ button: ASAuthorizationAppleIDButton) {
            guard let anchor = button.window else { return }
            let request = ASAuthorizationAppleIDProvider().createRequest()
            guard let id = app.prepareAppleSignIn(request) else { return }
            let operation = AppleAuthorizationOperation(anchor: anchor) { [self] result in
                operations.removeValue(forKey: id)
                Task { await app.completeAppleSignIn(result, operationID: id) }
            }
            operations[id] = operation
            operation.start(request)
        }
    }
}

@MainActor
private final class AppleAuthorizationOperation: NSObject, ASAuthorizationControllerDelegate,
                                                  ASAuthorizationControllerPresentationContextProviding {
    private let anchor: ASPresentationAnchor
    private let completion: (Result<ASAuthorization, Error>) -> Void
    private var controller: ASAuthorizationController?
    private var completed = false

    init(anchor: ASPresentationAnchor, completion: @escaping (Result<ASAuthorization, Error>) -> Void) {
        self.anchor = anchor
        self.completion = completion
    }

    func start(_ request: ASAuthorizationAppleIDRequest) {
        let controller = ASAuthorizationController(authorizationRequests: [request])
        self.controller = controller
        controller.delegate = self
        controller.presentationContextProvider = self
        controller.performRequests()
    }

    func presentationAnchor(for controller: ASAuthorizationController) -> ASPresentationAnchor { anchor }

    func authorizationController(controller: ASAuthorizationController, didCompleteWithAuthorization authorization: ASAuthorization) {
        finish(.success(authorization))
    }

    func authorizationController(controller: ASAuthorizationController, didCompleteWithError error: Error) {
        finish(.failure(error))
    }

    private func finish(_ result: Result<ASAuthorization, Error>) {
        guard !completed else { return }
        completed = true
        controller = nil
        completion(result)
    }
}
