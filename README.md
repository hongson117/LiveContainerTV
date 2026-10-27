# LiveContainerTV

tvOS port of the [LiveContainer](https://github.com/LiveContainer/LiveContainer) idea: run other tvOS apps inside one signed host so you only re-sign one app every 7 days (free Apple Developer account).

## Features (PoC)
- Built-in **GuestDemo** (proves in-process launch works)
- **HTTP import server on port 8228** — upload `.ipa` + signing `.p12` from your PC
- On-device Mach-O patch (`MH_EXECUTE` → `MH_DYLIB`) + **ZSign** re-sign with your cert
- On-screen diagnostics

## Get your .p12 (Windows / atvloadly / plumesign)
Certificates live under `%APPDATA%\PlumeImpactor\` (private key in `keys\<team_id>\key.pem`).

Export a P12 (empty password):
```bat
plumesign account export-p12 --email your@appleid.com --output certificate.p12
```
Or in Impactor GUI: select account → **Export P12**.

## Import an app
1. Install `LiveContainerTV.ipa` with atvloadly (same Apple ID you export the p12 from).
2. On the Apple TV, open LiveContainerTV — note the URL `http://<tv-ip>:8228`.
3. On your PC (same LAN), open that URL.
4. Upload `certificate.p12` (password empty unless you set one).
5. Upload a **tvOS** `.ipa` (arm64 Apple TV build — iPhone IPAs will not work).
6. On the TV, tap **Reload**, then tap the imported app → OK → reopen LiveContainerTV.

## Build
GitHub Actions (macos-15) fetches [krzyzanowskim/OpenSSL](https://github.com/krzyzanowskim/OpenSSL) (tvOS slice) and produces an unsigned IPA artifact.
