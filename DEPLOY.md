# Deploying Bandwatch to another Mac

## What you're shipping

`scripts/package-app.sh` produces `dist/Bandwatch-<version>-universal.zip`:

- a **universal** build (Apple Silicon **and** Intel — runs on any Mac)
- **ad-hoc signed** — no paid Apple Developer account, so it is **not notarized**

Rebuild it any time with:

```bash
./scripts/package-app.sh
```

## Requirements on the target Mac

- **macOS 15 (Sequoia) or newer** — this is a hard floor set in `Info.plist`.
  On an older macOS it will refuse to launch.
- A microphone / audio input.

## Install steps (on the target Mac)

**1. Copy the zip over** (AirDrop, USB, cloud drive, `scp` — any method) and unzip it.
Put `Bandwatch.app` wherever you like, e.g. `/Applications`.

**2. Remove the Gatekeeper quarantine.** This is the one required extra step,
and it exists because the app is ad-hoc signed rather than notarized. Any app
transferred from another machine is quarantined by macOS; for a notarized app
Gatekeeper clears it silently, but for this one you clear it manually:

```bash
xattr -dr com.apple.quarantine /Applications/Bandwatch.app
```

Without this, macOS says *"Bandwatch is damaged and can't be opened"* or
*"cannot be opened because the developer cannot be verified."* That message is
Gatekeeper refusing an un-notarized app — it does **not** mean the app is
actually damaged. The command above resolves it.

(Alternative without Terminal: **right-click the app → Open → Open** in the
dialog. On recent macOS this is less reliable for un-notarized apps than the
`xattr` command, so prefer the command if you have Terminal access.)

**3. Launch it and grant microphone access.** On first Start, macOS prompts for
the microphone. Grant it. If you ever deny it by mistake, re-enable under
**System Settings → Privacy & Security → Microphone**.

## Deploying to a dedicated always-on monitoring Mac

Bandwatch is built to run unattended (see the design spec), but two things are
worth setting on the target machine:

- **Prevent system sleep** while monitoring, or the audio input stops. The app
  itself does not yet hold a power assertion (that's a later milestone), so for
  now set **System Settings → Displays / Battery → prevent automatic sleep** on
  power, or use `caffeinate` alongside it.
- **If it's a laptop, keep the lid open** on power. Closing the lid suspends
  audio capture regardless of the app.
- Recordings and the database live at
  `~/Library/Application Support/Bandwatch/` on that machine.

## Why not notarized (and how to change that later)

Notarization would remove step 2 entirely — the app would open with a normal
double-click on any Mac. It requires:

1. An **Apple Developer account** ($99/year).
2. Signing with a **Developer ID Application** certificate instead of ad-hoc.
3. Submitting the app to Apple's notary service (`xcrun notarytool submit`) and
   stapling the ticket (`xcrun stapler staple`).

None of that changes the app's code — it's purely a signing/distribution step.
If you decide to distribute Bandwatch more widely, that's the upgrade path, and
`package-app.sh` is where the signing step would change.

## Note on microphone permission and re-signing

macOS ties microphone permission to bundle ID **plus** code signature. Because
the build is ad-hoc signed, a rebuilt copy has a slightly different signature,
so the target Mac may re-prompt for microphone access after an update. That's
expected. If permission ever gets into a stuck state:

```bash
tccutil reset Microphone com.bandwatch.Bandwatch
```
