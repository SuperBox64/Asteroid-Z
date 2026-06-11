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
`native-v*` tag. Jobs check out superbox64-spritekit@embedded from GitHub,
so the framework's local commits MUST be pushed before CI builds match.

Secrets for full signing: MACOS_CERT_P12/_PASSWORD/_SIGN_ID,
NOTARY_KEY_ID/ISSUER/KEY_P8, WINDOWS_CERT_PFX/_PASSWORD,
ANDROID_KEYSTORE/_PASSWORD.

Windows reality: Embedded Swift on COFF is unproven; the lane attempts it
and documents a stdlib fallback (still a single native exe). Android uses
SDL3's android-project template (SDLActivity + gradle) around a
cross-compiled libmain.so; first CI run will drive out the wrinkles.
