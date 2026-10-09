import Foundation
import Combine

struct NewsletterPreference: Decodable, Equatable {
    let accountId: String
    let subscribed: Bool
    let canSubscribe: Bool
    let promptPending: Bool
    let consentText: String
    let consentTextVersion: String
    let privacyUrl: URL
    let revision: UUID
}

struct UpdateNewsletterPreferenceRequest: Encodable {
    let subscribed: Bool
    let expectedRevision: UUID
    let consentTextVersion: String?
}

enum NewsletterOnboardingDecision: String, Encodable {
    case subscribe, skip
}

struct NewsletterOnboardingRequest: Encodable {
    let decision: NewsletterOnboardingDecision
    let expectedRevision: UUID
    let consentTextVersion: String?
}

struct NewsletterActionOrigin: Equatable {
    let accountId: String
    let generation: UInt
    let sessionEpoch: UInt64
}

struct NewsletterPreferenceSnapshot: Equatable {
    let preference: NewsletterPreference
    let origin: NewsletterActionOrigin
}

struct NewsletterPrompt: Identifiable {
    let preference: NewsletterPreference
    let origin: NewsletterActionOrigin
    var id: String { "\(origin.accountId):\(origin.generation):\(preference.revision)" }
}

/// Server state is authoritative; failed enrollment intents are never replayed.
@MainActor
final class NewsletterConsentModel: ObservableObject {
    @Published private(set) var snapshot: NewsletterPreferenceSnapshot?
    var preference: NewsletterPreference? { snapshot?.preference }
    @Published var prompt: NewsletterPrompt?
    @Published private(set) var isLoading = false
    @Published private(set) var isSaving = false
    @Published private(set) var errorMessage: String?
    private let api: BackendServicing
    private var accountId: String?
    private var accountSessionEpoch: UInt64?
    private var generation: UInt = 0

    init(api: BackendServicing) { self.api = api }

    func updateAccount(_ accountId: String?) {
        let epoch = accountId.map { _ in api.newsletterSessionEpoch }
        guard self.accountId != accountId || accountSessionEpoch != epoch else { return }
        generation &+= 1
        self.accountId = accountId
        accountSessionEpoch = epoch
        snapshot = nil
        prompt = nil
        isLoading = false
        isSaving = false
        errorMessage = nil
    }

    func refresh(showPrompt: Bool = false) async {
        guard let origin = currentOrigin, isCurrent(origin), !isLoading, !isSaving else { return }
        isLoading = true
        defer { if isCurrent(origin) { isLoading = false } }
        do {
            let loaded = try await api.fetchNewsletterPreference(expectedAccountId: origin.accountId, expectedSessionEpoch: origin.sessionEpoch)
            guard isCurrent(origin), loaded.accountId == origin.accountId else { return }
            snapshot = NewsletterPreferenceSnapshot(preference: loaded, origin: origin)
            errorMessage = nil
            if !loaded.promptPending { prompt = nil }
            else if showPrompt || prompt != nil { prompt = NewsletterPrompt(preference: loaded, origin: origin) }
        } catch is CancellationError {
        } catch {
            guard isCurrent(origin) else { return }
            errorMessage = error.localizedDescription
        }
    }

    // Capture the rendered wording, revision and account before scheduling work.
    func setSubscribed(_ subscribed: Bool, snapshot rendered: NewsletterPreferenceSnapshot) {
        guard isCurrent(rendered.origin), !isLoading, !isSaving,
              snapshot == rendered, rendered.preference.subscribed != subscribed,
              !subscribed || rendered.preference.canSubscribe else { return }
        startWrite(origin: rendered.origin, rendered: rendered.preference, subscribed: subscribed, decision: nil)
    }

    func decide(_ decision: NewsletterOnboardingDecision, prompt rendered: NewsletterPrompt) {
        guard isCurrent(rendered.origin), !isLoading, !isSaving,
              preference == rendered.preference, rendered.preference.promptPending,
              decision != .subscribe || rendered.preference.canSubscribe else { return }
        if decision == .skip { prompt = nil }
        startWrite(origin: rendered.origin, rendered: rendered.preference,
                   subscribed: decision == .subscribe, decision: decision)
    }

    private var currentOrigin: NewsletterActionOrigin? {
        accountId.map { NewsletterActionOrigin(accountId: $0, generation: generation, sessionEpoch: api.newsletterSessionEpoch) }
    }

    private func isCurrent(_ origin: NewsletterActionOrigin) -> Bool {
        currentOrigin == origin && api.storedSession?.userId == origin.accountId
    }

    private func startWrite(origin: NewsletterActionOrigin, rendered: NewsletterPreference,
                            subscribed: Bool, decision: NewsletterOnboardingDecision?) {
        guard isCurrent(origin) else { return }
        isSaving = true
        errorMessage = nil
        Task { @MainActor [weak self] in
            guard let self, self.isCurrent(origin) else { return }
            defer { if self.isCurrent(origin) { self.isSaving = false } }
            do {
                let updated: NewsletterPreference
                if let decision {
                    updated = try await self.api.completeNewsletterOnboarding(
                        decision: decision, expectedRevision: rendered.revision,
                        consentTextVersion: decision == .subscribe ? rendered.consentTextVersion : nil,
                        expectedAccountId: origin.accountId, expectedSessionEpoch: origin.sessionEpoch)
                } else {
                    updated = try await self.api.updateNewsletterPreference(
                        subscribed: subscribed, expectedRevision: rendered.revision,
                        consentTextVersion: subscribed ? rendered.consentTextVersion : nil,
                        expectedAccountId: origin.accountId, expectedSessionEpoch: origin.sessionEpoch)
                }
                guard self.isCurrent(origin), updated.accountId == origin.accountId else { return }
                self.snapshot = NewsletterPreferenceSnapshot(preference: updated, origin: origin)
                if !updated.promptPending { self.prompt = nil }
            } catch is CancellationError {
            } catch {
                guard self.isCurrent(origin) else { return }
                let message: String
                if let failure = error as? APIError, failure.statusCode == 409 {
                    message = "Your newsletter preference or consent wording changed. Review the current choice and try again."
                } else { message = error.localizedDescription }
                self.errorMessage = message
                // Lost replies may have saved. Read state, never repeat the write.
                if let current = try? await self.api.fetchNewsletterPreference(expectedAccountId: origin.accountId, expectedSessionEpoch: origin.sessionEpoch),
                   self.isCurrent(origin), current.accountId == origin.accountId {
                    self.snapshot = NewsletterPreferenceSnapshot(preference: current, origin: origin)
                    if !current.promptPending { self.prompt = nil }
                    else if decision != .skip, self.prompt != nil {
                        self.prompt = NewsletterPrompt(preference: current, origin: origin)
                    }
                    self.errorMessage = message
                }
            }
        }
    }
}
