# Google Sign-In configuration

The app target is wired to GoogleSignIn 9.x and expects three user-defined build settings:

- `GOOGLE_IOS_CLIENT_ID`: the Google OAuth client of type iOS for bundle ID `net.libreguard.libreguard-vpn-ios`.
- `GOOGLE_REVERSED_CLIENT_ID`: the reversed iOS client ID used as the callback URL scheme.
- `GOOGLE_SERVER_CLIENT_ID`: the existing Web OAuth client ID accepted by ManagementPanel.

Replace the `*_NOT_CONFIGURED` placeholders in both app target build configurations. The values are expanded into `Info.plist`; no client secret belongs in the iOS project.

ManagementPanel must continue accepting `GOOGLE_SERVER_CLIENT_ID` as an allowed audience for `POST /api/login/google` and the OAuth pre-auth device-removal endpoint.
