import Foundation
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
    case unverified
}

enum AppleStoreError: LocalizedError {
    case productsUnavailable
    case unverifiedTransaction
    case unknownPurchaseResult

    var errorDescription: String? {
        switch self {
        case .productsUnavailable:
            "Apple subscriptions are temporarily unavailable. Please try again later."
        case .unverifiedTransaction:
            "The App Store could not verify this purchase. No changes were made to your account."
        case .unknownPurchaseResult:
            "The App Store returned an unsupported purchase result. Please try again."
        }
    }
}

@MainActor
protocol AppleSubscriptionStoreServing: AnyObject {
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

    func loadProducts() async throws -> [AppleSubscriptionProduct] {
        let products = try await Product.products(for: AppleSubscriptionCatalog.productIDs)
        productsByID = Dictionary(uniqueKeysWithValues: products.map { ($0.id, $0) })

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
        guard let period = product.subscription?.subscriptionPeriod else { return nil }
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
        case .unverified:
            .unverified
        }
    }

    private func cache(_ transaction: Transaction, signedTransactionInfo: String) -> AppleStoreTransaction {
        transactionsByID[transaction.id] = transaction
        return AppleStoreTransaction(
            id: transaction.id,
            productID: transaction.productID,
            signedTransactionInfo: signedTransactionInfo
        )
    }
}
