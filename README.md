# LiveContainerTV (proof of concept)

Minimal tvOS port of the [LiveContainer](https://github.com/LiveContainer/LiveContainer) idea: the host loads a guest tvOS app's main executable (patched `MH_EXECUTE`→`MH_DYLIB`) with `dlopen` and jumps to its `LC_MAIN`, so only the host needs signing.

## PoC limits
- Guest is embedded at build time as `Frameworks/GuestDemo.framework` so atvloadly/plumesign signs it with the same team cert.
- No in-app signing, no IPA import, no container isolation yet.
- Pending guest is stored in `Library/Caches/lctv_pending_guest.txt` (NSUserDefaults + `exit(0)` was unreliable on tvOS).
- Diagnostics are written to `Library/Caches/lctv_diag.log` and shown on the host list screen.

## Build
GitHub Actions (macos-15) produces an unsigned `LiveContainerTV.ipa` artifact.
