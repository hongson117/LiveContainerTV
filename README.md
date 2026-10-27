# LiveContainerTV

tvOS port of the [LiveContainer](https://github.com/LiveContainer/LiveContainer) idea: run other tvOS apps inside one signed host so you only re-sign one app every 7 days (free Apple Developer account).

## Features (PoC)
- Built-in **GuestDemo** (proves in-process launch works)
- **HTTP import server on port 8228** — upload `.ipa` + signing `.p12` from your PC
- On-device Mach-O patch (`MH_EXECUTE` → `MH_DYLIB`) + **ZSign** re-sign with your cert
- Robust multipart upload (Expect: 100-continue, stream large IPAs to disk, HTML errors)
- Pending guest launch is single-shot and time-limited — crash/relaunch always returns to the host list
- GuestDemo: **Menu** or **Return to host** goes back to the host list

## Get your .p12 (Windows / atvloadly / plumesign)

Password is **required** (plumesign will not export without `-p`):

```bat
plumesign certificate export -u your@appleid.com -p YOURPASS -o certificate.p12
```

Use the same password when uploading on the web UI.  
(Do **not** use `account export-p12` — that subcommand does not exist.)

Certificates live under `%APPDATA%\PlumeImpactor\` (private key in `keys\<team_id>\key.pem`).

## Import an app
1. Install `LiveContainerTV.ipa` with atvloadly (same Apple ID you export the p12 from).
2. On the Apple TV, open LiveContainerTV — note the URL `http://<tv-ip>:8228`.
3. On your PC (same LAN), open that URL.
4. Upload `certificate.p12` and enter the **same password** you passed to `-p`.
5. Upload a **tvOS** `.ipa` (arm64 Apple TV build — iPhone IPAs will not work).
6. On the TV, tap **Reload**, then the imported app → **Launch** → **OK — close & relaunch** → reopen LiveContainerTV within ~90 seconds.

## Guest launch / return to host
- Pending launch is written only when you confirm OK, and cleared the moment it is read.
- If the app crashes or you reopen later than ~90s, you get the **host list** (not a stuck GuestDemo).
- From GuestDemo: press **Menu** on the remote, or the **Return to LiveContainerTV host** button, then reopen the app.

## Build
GitHub Actions (macos-15) fetches [krzyzanowskim/OpenSSL](https://github.com/krzyzanowskim/OpenSSL) (tvOS slice) and produces an unsigned IPA artifact.
