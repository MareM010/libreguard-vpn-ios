import CryptoKit
import Foundation
import OSLog
import Security

protocol IKEv2GatewayCertificateTypeResolving {
    func resolve(host: String, port: Int) async -> IKEv2ClientCertificateKeyType?
}

/// Detects the public-key type used by the VPN server's HTTPS health endpoint.
///
/// LibreGuard deploys the same Let's Encrypt certificate to the health API and
/// strongSwan. The probe never relaxes TLS validation; it only records the leaf
/// certificate after the system has accepted the HTTPS connection.
final class HTTPSIKEv2GatewayCertificateTypeResolver: IKEv2GatewayCertificateTypeResolving {
    private let timeoutInterval: TimeInterval
    private let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "libreguard-vpn-ios",
        category: "IKEv2GatewayCertificate"
    )

    init(timeoutInterval: TimeInterval = 3) {
        self.timeoutInterval = max(timeoutInterval, 0.1)
    }

    func resolve(host: String, port: Int) async -> IKEv2ClientCertificateKeyType? {
        guard let url = Self.pingURL(host: host, port: port) else {
            logger.error("Skipping IKEv2 gateway certificate probe because its endpoint is invalid")
            return nil
        }

        let delegate = GatewayCertificateCaptureDelegate()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeoutInterval
        configuration.timeoutIntervalForResource = timeoutInterval
        let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = timeoutInterval

        do {
            let (_, response) = try await session.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse,
                  (200..<300).contains(httpResponse.statusCode),
                  let resolution = delegate.resolution else {
                logger.error(
                    "IKEv2 gateway certificate probe returned no usable trusted leaf for host=\(host, privacy: .public) port=\(port, privacy: .public)"
                )
                return nil
            }

            logger.info(
                "Resolved IKEv2 gateway certificate host=\(host, privacy: .public) port=\(port, privacy: .public) keyType=\(resolution.keyType.rawValue, privacy: .public) certificateFingerprint=\(resolution.abbreviatedFingerprint, privacy: .public)"
            )
            return resolution.keyType
        } catch is CancellationError {
            return nil
        } catch {
            logger.error(
                "IKEv2 gateway certificate probe failed for host=\(host, privacy: .public) port=\(port, privacy: .public): \(Self.describe(error), privacy: .public)"
            )
            return nil
        }
    }

    private static func pingURL(host: String, port: Int) -> URL? {
        guard !host.isEmpty, (1...65_535).contains(port) else { return nil }

        var components = URLComponents()
        components.scheme = "https"
        components.host = host
        components.port = port
        components.path = "/ping"
        return components.url
    }

    private static func describe(_ error: Error) -> String {
        let nsError = error as NSError
        return "\(nsError.domain)(\(nsError.code)): \(nsError.localizedDescription)"
    }
}

private struct IKEv2GatewayCertificateResolution {
    let keyType: IKEv2ClientCertificateKeyType
    let abbreviatedFingerprint: String
}

private final class GatewayCertificateCaptureDelegate: NSObject, URLSessionDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var capturedResolution: IKEv2GatewayCertificateResolution?

    var resolution: IKEv2GatewayCertificateResolution? {
        lock.lock()
        defer { lock.unlock() }
        return capturedResolution
    }

    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        defer { completionHandler(.performDefaultHandling, nil) }

        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust,
              let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate],
              let leafCertificate = chain.first,
              let keyType = try? IKEv2CertificateKeyTypeResolver.resolve(leafCertificate) else {
            return
        }

        let certificateDER = SecCertificateCopyData(leafCertificate) as Data
        let fingerprint = SHA256.hash(data: certificateDER)
            .prefix(6)
            .map { String(format: "%02x", $0) }
            .joined()

        lock.lock()
        capturedResolution = IKEv2GatewayCertificateResolution(
            keyType: keyType,
            abbreviatedFingerprint: fingerprint
        )
        lock.unlock()
    }
}
