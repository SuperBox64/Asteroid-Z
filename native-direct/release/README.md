# Native release pipeline (no wasm, no webview)

| Platform | Status | Output | Signing |
|---|---|---|---|
| macOS | ✓ working, verified locally | AsteroidZ.app in zip (~800 KB) | Developer ID + hardened runtime; notarize via NOTARY_PROFILE |
| Linux | scripted, runs on CI | static bin + .deb | n/a |
| Windows | experimental lane | .exe | signtool, gated on WINDOWS_CERT_PFX |
| Android | experimental lane | .apk | apksigner, gated on ANDROID_KEYSTORE |

Local macOS:
```sh
native-direct/release/build-macos.sh
NOTARY_PROFILE=MyProfile native-direct/release/build-macos.sh   # after notarytool store-credentials
```

CI: `.github/workflows/native-release.yml` - dispatch manually or push a
`native-v*` tag. Jobs check out SuperBox64Kit@embedded from GitHub,
so the framework's local commits MUST be pushed before CI builds match.

The macOS lane signs and notarizes IN CI. Required repo secrets:

| Secret | Contents |
|---|---|
| MACOS_CERT_P12 | base64 of the Developer ID Application .p12 export |
| MACOS_CERT_PASSWORD | the .p12 password |
| MACOS_SIGN_ID | "Developer ID Application: Todd Bruss (469UCUB275)" |
| NOTARY_KEY_ID | App Store Connect API key id |
| NOTARY_ISSUER | App Store Connect issuer id |
| NOTARY_KEY_P8 | base64 of the AuthKey_XXXX.p8 |
| WINDOWS_CERT_PFX/_PASSWORD | Windows code signing (optional) |
| ANDROID_KEYSTORE/_PASSWORD | apk signing (optional) |

Export the p12: Keychain Access > Developer ID Application > Export, then
`base64 -i cert.p12 | pbcopy`. The API key comes from App Store Connect >
Users and Access > Integrations. Without cert secrets the lane still builds
an ad-hoc-signed zip so the pipeline never blocks.

Windows reality: Embedded Swift on COFF is unproven; the lane attempts it
and documents a stdlib fallback (still a single native exe). Android uses
SDL3's android-project template (SDLActivity + gradle) around a
cross-compiled libmain.so; first CI run will drive out the wrinkles.
