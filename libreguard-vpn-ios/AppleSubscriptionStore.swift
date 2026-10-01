import Foundation
import OSLog
import StoreKit

enum AppleSubscriptionCatalog {
    static let monthlyProductID = "net.libreguard.pro.monthly"
    static let annualProductID = "net.libreguard.pro.annual"
    static let productIDs = [monthlyProductID, annualProductID]
}

enum AppleSubscriptionPeriod: String, Sendable {
    case monthly
    case annual
}

enum AppleAPIEnvironment: Equatable, Sendable {
    case production
    case sandbox
    case xcode

    init(_ environment: AppStore.Environment) {
        switch environment {
        case .production: self = .production
        case .sandbox: self = .sandbox
        default: self = .xcode
        }
    }
}

struct AppleSubscriptionProduct: Identifiable, Equatable, Sendable {
    let id: String
    let displayName: String
    let description: String
    let displayPrice: String
    let price: Decimal
    let period: AppleSubscriptionPeriod
}

struct AppleStoreTransaction: Equatable, Sendable {
    let id: UInt64
    let productID: String
    let signedTransactionInfo: String
    let environment: AppleAPIEnvironment
    let purchaseDate: Date?
    let expirationDate: Date?

    init(id: UInt64, productID: String, signedTransactionInfo: String,
         environment: AppleAPIEnvironment, purchaseDate: Date? = nil, expirationDate: Date? = nil) {
        self.id = id
        self.productID = productID
        self.signedTransactionInfo = signedTransactionInfo
        self.environment = environment
        self.purchaseDate = purchaseDate
        self.expirationDate = expirationDate
    }
}

struct PendingAppleSubscriptionTransfer: Identifiable, Equatable, Sendable {
    var id: UInt64 { transaction.id }
    let transaction: AppleStoreTransaction
}

enum ApplePurchaseResult: Equatable, Sendable {
    case success(AppleStoreTransaction)
    case pending
    case userCancelled
}

enum AppleStoreUpdate: Sendable {
    case verified(AppleStoreTransaction)
    case unverified(productID: String, message: String)
}

enum AppleStoreError: LocalizedError {
    case productsUnavailable
    case unverifiedTransaction
    case unknownPurchaseResult
    case unavailableEnvironment
    case unsupportedEnvironment

    var errorDescription: String? {
        switch self {
        case .productsUnavailable:
            "Apple subscriptions are temporarily unavailable. Please try again later."
        case .unverifiedTransaction:
            "The App Store could not verify this purchase. No changes were made to your account."
        case .unknownPurchaseResult:
            "The App Store returned an unsupported purchase result. Please try again."
        case .unavailableEnvironment:
            "The App Store environment could not be verified. Check your Apple account and try again."
        case .unsupportedEnvironment:
            "Local Xcode StoreKit purchases cannot activate LibreGuard Pro because Apple does not sign them. In Xcode, set the Run scheme's StoreKit Configuration to None, then purchase with an Apple Sandbox tester."
        }
    }
}

@MainActor
protocol AppleSubscriptionStoreServing: AnyObject {
    var canMakePayments: Bool { get }
    func purchaseEnvironment() async throws -> AppleAPIEnvironment
    func loadProducts() async throws -> [AppleSubscriptionProduct]
    func purchase(productID: String, appAccountToken: UUID) async throws -> ApplePurchaseResult
    func sync() async throws
    func currentEntitlements() async -> [AppleStoreUpdate]
    func unfinishedTransactions() async -> [AppleStoreUpdate]
    func transactionUpdates() -> AsyncStream<AppleStoreUpdate>
    func finish(transactionID: UInt64) async
}

@MainActor
final class AppleSubscriptionStore: AppleSubscriptionStoreServing {
    private var productsByID: [String: Product] = [:]
    private var transactionsByID: [UInt64: Transaction] = [:]
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "net.libreguard.libreguard-vpn-ios", category: "AppleSubscription")

    var canMakePayments: Bool { AppStore.canMakePayments }

    func purchaseEnvironment() async throws -> AppleAPIEnvironment {
        do {
            return try environment(from: try await AppTransaction.shared)
        } catch {
            logEnvironmentFailure(error, operation: "AppTransaction.shared")
        }
        do {
            // This method is called only from the Subscribe action. Refresh may prompt for Apple credentials.
            return try environment(from: try await AppTransaction.refresh())
        } catch {
            logEnvironmentFailure(error, operation: "AppTransaction.refresh")
            throw AppleStoreError.unavailableEnvironment
        }
    }

    private func environment(from result: VerificationResult<AppTransaction>) throws -> AppleAPIEnvironment {
        switch result {
        case let .verified(transaction): AppleAPIEnvironment(transaction.environment)
        case .unverified: throw AppleStoreError.unverifiedTransaction
        }
    }

    private func logEnvironmentFailure(_ error: Error, operation: String) {
        let nsError = error as NSError
        logger.error("\(operation, privacy: .public) failed [\(nsError.domain, privacy: .public):\(nsError.code, privacy: .public)]")
    }

    func loadProducts() async throws -> [AppleSubscriptionProduct] {
        let products = try await Product.products(for: AppleSubscriptionCatalog.productIDs)
        productsByID = Dictionary(uniqueKeysWithValues: products.filter { $0.type == .autoRenewable }.map { ($0.id, $0) })

        let mapped = products.compactMap(Self.mapProduct)
        guard mapped.count == AppleSubscriptionCatalog.productIDs.count else {
            throw AppleStoreError.productsUnavailable
        }
        return mapped.sorted { lhs, rhs in
            if lhs.period == rhs.period { return lhs.price < rhs.price }
            return lhs.period == .annual
        }
    }

    func purchase(productID: String, appAccountToken: UUID) async throws -> ApplePurchaseResult {
        let product: Product
        if let cached = productsByID[productID] {
            product = cached
        } else {
            _ = try await loadProducts()
            guard let loaded = productsByID[productID] else {
                throw AppleStoreError.productsUnavailable
            }
            product = loaded
        }

        let result = try await product.purchase(options: [.appAccountToken(appAccountToken)])
        switch result {
        case let .success(verification):
            switch verification {
            case let .verified(transaction):
                return .success(cache(transaction, signedTransactionInfo: verification.jwsRepresentation))
            case .unverified:
                throw AppleStoreError.unverifiedTransaction
            }
        case .pending:
            return .pending
        case .userCancelled:
            return .userCancelled
        @unknown default:
            throw AppleStoreError.unknownPurchaseResult
        }
    }

    func sync() async throws {
        try await AppStore.sync()
    }

    func currentEntitlements() async -> [AppleStoreUpdate] {
        var updates: [AppleStoreUpdate] = []
        for await result in Transaction.currentEntitlements {
            updates.append(map(result))
        }
        return updates
    }

    func unfinishedTransactions() async -> [AppleStoreUpdate] {
        var updates: [AppleStoreUpdate] = []
        for await result in Transaction.unfinished {
            updates.append(map(result))
        }
        return updates
    }

    func transactionUpdates() -> AsyncStream<AppleStoreUpdate> {
        AsyncStream { continuation in
            let task = Task { @MainActor [weak self] in
                guard let self else { return }
                for await result in Transaction.updates {
                    guard !Task.isCancelled else { break }
                    continuation.yield(map(result))
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    func finish(transactionID: UInt64) async {
        guard let transaction = transactionsByID.removeValue(forKey: transactionID) else { return }
        await transaction.finish()
    }

    private static func mapProduct(_ product: Product) -> AppleSubscriptionProduct? {
        guard product.type == .autoRenewable, let period = product.subscription?.subscriptionPeriod else { return nil }
        let mappedPeriod: AppleSubscriptionPeriod
        switch (period.unit, period.value) {
        case (.month, 1): mappedPeriod = .monthly
        case (.year, 1): mappedPeriod = .annual
        default: return nil
        }
        return AppleSubscriptionProduct(
            id: product.id,
            displayName: product.displayName,
            description: product.description,
            displayPrice: product.displayPrice,
            price: product.price,
            period: mappedPeriod
        )
    }

    private func map(_ result: VerificationResult<Transaction>) -> AppleStoreUpdate {
        switch result {
        case let .verified(transaction):
            .verified(cache(transaction, signedTransactionInfo: result.jwsRepresentation))
        case let .unverified(transaction, error):
            .unverified(productID: transaction.productID, message: error.localizedDescription)
        }
    }

    private func cache(_ transaction: Transaction, signedTransactionInfo: String) -> AppleStoreTransaction {
        transactionsByID[transaction.id] = transaction
        return AppleStoreTransaction(
            id: transaction.id,
            productID: transaction.productID,
            signedTransactionInfo: signedTransactionInfo,
            environment: AppleAPIEnvironment(transaction.environment),
            purchaseDate: transaction.purchaseDate,
            expirationDate: transaction.expirationDate
        )
    }
}
