import SwiftUI

struct NewsletterConsentPresenter: View {
    @ObservedObject var model: NewsletterConsentModel

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .sheet(item: $model.prompt) { prompt in
                NewsletterOnboardingView(model: model, prompt: prompt)
                    .presentationDetents([.medium, .large])
                    .interactiveDismissDisabled(model.isSaving)
            }
    }
}

private struct NewsletterOnboardingView: View {
    @ObservedObject var model: NewsletterConsentModel
    let prompt: NewsletterPrompt

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Stay in touch").font(.title2.bold())
            Text("Your account is ready. Newsletter signup is optional.")
                .foregroundStyle(.secondary)
            Text(prompt.preference.consentText)
            Text("You can unsubscribe at any time in account settings or any newsletter.")
                .font(.subheadline).foregroundStyle(.secondary)
            if prompt.preference.privacyUrl.scheme == "https" {
                Link("Privacy Policy", destination: prompt.preference.privacyUrl)
            }
            if !prompt.preference.canSubscribe {
                Text("Verify your account email before subscribing.")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
            if let message = model.errorMessage {
                Text(message).font(.subheadline).foregroundStyle(.red)
            }
            if model.isSaving { ProgressView("Saving your choice...") }
            Button("Subscribe") { model.decide(.subscribe, prompt: prompt) }
                .buttonStyle(.borderedProminent)
                .disabled(!prompt.preference.canSubscribe || model.isSaving || model.isLoading)
                .accessibilityIdentifier("newsletter-onboarding-subscribe")
            Button("Skip") { model.decide(.skip, prompt: prompt) }
                .disabled(model.isSaving || model.isLoading)
                .accessibilityIdentifier("newsletter-onboarding-skip")
        }
        .padding(28)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct NewsletterAccountSettingsView: View {
    @ObservedObject var model: NewsletterConsentModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Account").font(.headline)
            if let snapshot = model.snapshot {
                let preference = snapshot.preference
                Toggle("Newsletter", isOn: Binding(
                    get: { preference.subscribed },
                    set: { model.setSubscribed($0, snapshot: snapshot) }
                ))
                .disabled(model.isLoading || model.isSaving || (!preference.subscribed && !preference.canSubscribe))
                .accessibilityIdentifier("newsletter-settings-toggle")
                Text(preference.consentText).font(.subheadline).foregroundStyle(.secondary)
                Text("Unsubscribe here or through any newsletter email.")
                    .font(.caption).foregroundStyle(.secondary)
                if !preference.canSubscribe && !preference.subscribed {
                    Text("Verify your account email before subscribing.")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
                if preference.privacyUrl.scheme == "https" {
                    Link("Privacy Policy", destination: preference.privacyUrl).font(.subheadline)
                }
            } else {
                Text("Newsletter preference is not loaded.").foregroundStyle(.secondary)
            }
            if model.isLoading || model.isSaving { ProgressView("Updating newsletter preference...") }
            if let message = model.errorMessage {
                Text(message).font(.subheadline).foregroundStyle(.red)
                Button("Retry") { Task { await model.refresh() } }
                    .disabled(model.isLoading || model.isSaving)
            }
        }
        .padding(16)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 14))
        .task { await model.refresh() }
    }
}
