# Secure Google sign-in setup

AppAuth **3.0.0** performs authorization only through the system browser. The
backend generates state, nonce and S256 PKCE; it retains the verifier, exchanges
the one-use code and validates Google's identity token. The app has no Google
client secret, provider token, server client ID, PKCE verifier or persisted
OIDAuthState. Public native client IDs belong in app configuration.

Only LibreGuard session credentials/device keys persist in device-only Keychain.
Authorization codes, redemption capabilities and device continuations remain in
memory and are discarded on cancellation, expiry, sign-out, failure or success.
Late callbacks cannot restore a discarded attempt.

## Exact Google Console setup

1. Select the Google Cloud project used by LibreGuard.
2. In **Google Auth Platform > Branding**, confirm app/contact details, homepage,
   privacy policy and authorized domains.
3. In **Audience**, use External for public distribution; add acceptance test
   accounts while the consent application is in Testing.
4. In **Data Access**, this flow requests only openid email. Retain scopes needed
   by other integrations.
5. In **Clients > Create client**, choose **iOS**, name **LibreGuard iOS**, bundle
   ID **net.libreguard.libreguard-vpn-ios**, Team ID **4P475Q5Y45**. Supply the actual
   App Store ID only if a published listing exists.
6. Leave Firebase App Check client protection disabled for this AppAuth flow,
   which supplies no Google App Check assertions.
7. Copy this new client ID and displayed iOS URL scheme. This registration must
   differ from Android, Windows/Linux, website and macOS registrations. The macOS
   app requires its own separate client of type iOS.
8. Complete any Google-required consent verification before public release.

References: [native flow](https://developers.google.com/identity/protocols/oauth2/native-app),
[Apple setup](https://developers.google.com/identity/sign-in/ios/start-integrating),
[Console fields](https://support.google.com/cloud/answer/15549257).

## Public app configuration

Set these app target build settings in **both Debug and Release**:

| Setting | Placeholder | Replacement |
|---|---|---|
| GOOGLE_IOS_CLIENT_ID | IOS_CLIENT_ID_HERE | New iOS native client ID |
| GOOGLE_REVERSED_CLIENT_ID | IOS_REVERSED_CLIENT_ID_HERE | Exact displayed iOS URL scheme |

Info.plist expands them into LibreGuardGoogleClientID,
LibreGuardGoogleCallbackScheme and CFBundleURLSchemes. The app checks the ID,
reversed scheme and scheme registration before enabling Google buttons. The
exact callback is **REVERSED_CLIENT_ID:/oauth2callback**, with one slash and no
host. The libreguardvpn password-reset callback stays registered.

The Google button uses an unmodified official pre-approved PNG, preserving its
aspect ratio. Asset attribution and branding requirements appear in
THIRD_PARTY_NOTICES.md.

## Backend contract and rollout

Deploy the coordinated ManagementPanel database/backend changes first:

- POST /api/login/google/native/begin: platform ios, device metadata/public key,
  optional newsletter consent. Returns attemptId, redemptionToken, expiresAt,
  clientId, redirectUri, state, nonce and codeChallenge.
- POST /api/login/google/native/complete: attemptId, redemptionToken, code, state.
- Existing /api/login/verify-2fa and /api/login/verify-recovery-code handle MFA.
- POST /api/login/google/native/continue: loginContinuationToken and
  deviceIdsToRemove. Device-limit responses include loginContinuationToken and
  loginContinuationExpiresAt.

Configure Authentication:Google:AppleNative:Ios:ClientId with the same public ID.
Keep Enabled false until acceptance testing, then enable the iOS profile. Never
add this ID to the legacy Google token/code/device-removal audience allowlists.

GOOGLE_LINK_REQUIRED opens the fixed management External Logins page. The user
proves their existing account, completes required MFA and explicitly links
Google, then starts a fresh Google login in the app. Matching email alone must
never link accounts.

Google device removal uses a single-use backend continuation, including after
TOTP/recovery. It never repeats the Google code or provider-token authentication.
An ambiguous exchange/removal response requires a fresh interactive login.
Invalid factor/recovery codes and retriable factor security/rate-limit failures
retain only the unexpired pending challenge. Cancellation is dismissal.
Closing the device-limit sheet discards its capability.

## Verification and release gate

The shared libreguard-vpn-ios scheme runs unit tests. CI requires installed Xcode
and an iPhone Simulator runtime supporting the existing **iOS 26.5** target and
fails with an actionable message on an older hosted image.

Tests cover native request bodies; no automatic exchange retries; authorization
URL/state/nonce/S256; exact callbacks; wrong or placeholder configuration; no
presenter; cancellation/duplicate login/late responses; account linking guidance;
MFA and device continuation; ticket rotation; ambiguous continuation failures.
Existing Apple/password/session/VPN/certificate tests remain included.

Run signed browser roundtrips on physical iPhone and iPad before release:

- Existing-account login, new-account signup and LibreGuard session restoration.
- Cancellation, wrong callback/state, expiry, duplicate or late callbacks.
- TOTP/recovery before device disclosure/removal and expired/rotated continuations.
- Existing-email linking through fresh account proof plus required MFA.
- Offline/timeout after exchange or removal, requiring fresh Google login.
- Apple/password authentication, password reset and VPN regression checks.
- Branding/layout in light/dark mode, Dynamic Type and compact iPhone/iPad views.

This Windows workspace cannot build Xcode targets or perform signed browser
roundtrips. Static validation does not replace these release checks.
