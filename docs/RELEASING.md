# Releasing Ketto

Every push to `main` cuts a signed, notarized release and hands it to everyone already
running the app. Nothing here is manual once the secrets below exist.

```
push to main
  └─ test           build + the unit tests                      (macos-26)
      └─ bump       next version → stamp project → tag vX.Y.Z   (ubuntu)
          └─ build  archive → Developer ID → notarize → staple  (macos-26)
                    ├─ Ketto-X.Y.Z.dmg          what a new user downloads
                    ├─ Ketto-macos.dmg          version-less alias for a stable URL
                    ├─ Ketto-X.Y.Z.zip          what Sparkle installs in place
                    ├─ appcast.xml              the feed every installed copy polls
                    ├─ Ketto-X.Y.Z-dSYMs.zip
                    └─ SHA256SUMS
```

The running app reads
`https://github.com/boat-builder/ketto/releases/latest/download/appcast.xml`, which
always resolves to the newest release's copy, downloads the zip named in it, checks the
EdDSA signature against the public key in its own `Info.plist`, swaps the bundle in place
and relaunches. See `Ketto/App/UpdateController.swift` for the app side and
`.github/workflows/release.yml` for the CI side.

## One-time setup

Until all seven secrets exist the release job fails on its first step, before building.

### 1. Developer ID certificate — three secrets

You need a **Developer ID Application** certificate from a paid Apple Developer account.
Create it in Xcode (Settings → Accounts → Manage Certificates → + → Developer ID
Application) or at developer.apple.com, then export it from Keychain Access as a `.p12`
with a password.

| Secret | Value |
|---|---|
| `MACOS_CERTIFICATE` | `base64 -i Certificates.p12 \| pbcopy` |
| `MACOS_CERTIFICATE_PWD` | the password you exported the `.p12` with |
| `MACOS_SIGNING_IDENTITY` | the full identity name, e.g. `Developer ID Application: Your Name (AB12CD34EF)` — `security find-identity -v -p codesigning` prints it |

### 2. Notarization — three secrets

| Secret | Value |
|---|---|
| `APPLE_ID` | the Apple ID of that developer account |
| `APPLE_PASSWORD` | an **app-specific password** from appleid.apple.com, not the account password |
| `APPLE_TEAM_ID` | the 10-character team ID, on the top right of developer.apple.com |

These six reuse the names `doklin` and `bluesnake` use, so the values can be copied across
verbatim.

### 3. Sparkle update-signing key — one secret plus one commit

Developer ID proves the app is yours to macOS. Sparkle's EdDSA key is separate, and proves
to an *already installed* copy that the bytes it just downloaded are the ones you built.
Both are required.

```bash
./Scripts/generate-sparkle-keys.sh
```

It creates the key pair (private half into your login Keychain), and prints exactly what to
do with each half:

- the **public** key replaces `SPARKLE_PUBLIC_KEY_NOT_SET` in `Ketto/Info.plist` under
  `SUPublicEDKey`, and gets committed;
- the **private** key goes into the repository secret `SPARKLE_PRIVATE_KEY`.

Generate this **once**, and keep the Keychain entry and a backup. Regenerating it later
strands every copy already installed: they verify against the old public key, so they
reject every update signed with the new private key and can only be moved forward by a
manual re-download.

The app refuses to start Sparkle while the placeholder is in place, so a checkout without
the key behaves normally instead of showing a misconfiguration alert — and the release job
refuses to publish such a build at all.

## Cutting a release

Merge to `main`. That is the whole procedure.

- **Patch** (the default): the version is the latest `v*` tag with its patch bumped.
- **Minor or major**: raise `MARKETING_VERSION` in `Ketto.xcodeproj/project.pbxproj`
  in your own commit. A committed version higher than the latest tag is used verbatim.
- **Manual**: run the `release` workflow from the Actions tab (`workflow_dispatch`).

The bump job stamps that version into all four `MARKETING_VERSION`
(`CFBundleShortVersionString`) and `CURRENT_PROJECT_VERSION` (`CFBundleVersion`) entries,
commits it back to `main` as `chore: release vX.Y.Z [skip ci]` and tags it. Both keys carry
the same `X.Y.Z`, which is what Sparkle compares against `sparkle:version` in the appcast —
one number to reason about, not two.

## What users see

- **First install** is a manual download: the `.dmg`, drag to Applications. It is signed and
  notarized, so there is no Gatekeeper warning and no right-click-Open dance.
- **Every release after that** installs itself. Sparkle checks daily in the background,
  downloads, and applies the update the next time the app quits
  (`SUEnableAutomaticChecks` and `SUAutomaticallyUpdate` are both on by default in
  `Info.plist`). **Check for Updates…** in the Ketto menu, or the button in the top
  right of the recorder, does it immediately instead.
- **Nothing appears during a recording.** `AppModel` hides every app window while capturing
  so it stays out of the video, and Sparkle is held to the same rule through its gentle
  scheduled reminders — a pending update shows as a badge in the recorder afterwards
  instead of a window mid-take.
- **Screen Recording permission survives updates.** macOS keys that grant to the code
  signature, and every release carries the same Developer ID signature. A locally built
  copy is ad-hoc signed, so switching from one to a release build re-prompts once — after
  that it sticks.
- If the app sits in `/Applications` and is owned by root, Sparkle asks for an
  administrator password once to write the new bundle. That is macOS, not Sparkle.

## When something goes wrong

**Notarization takes too long or fails.** Apple occasionally sits on a submission. The job
fails; re-run it from the Actions tab with "Re-run failed jobs", which reuses the tag the
bump job already pushed and resubmits. `Scripts/notarize.sh` prints Apple's submission log
on rejection — that log names the specific nested binary or entitlement it objected to,
which the bare `notarytool` output does not.

**The tag exists but there is no release.** The bump succeeded and the build did not. Fix
the cause and re-run the failed jobs; do not delete the tag and re-push, and do not bump
again — the workflow refuses to reuse a tag that already exists.

**An update installs but the app will not launch.** The release artifacts are stapled, so
this is not Gatekeeper. Check the dSYM zip from that release against the crash report.

**A golden-frame test fails only on CI.** `GoldenFrameTests` compares rendered Metal
output against committed PNGs within a tight tolerance, and the runner's virtualised GPU is
not the machine the references were recorded on. If a failure reproduces nowhere else,
widen the tolerance in `KettoTests/GoldenFrameTests.swift` rather than re-recording the
references from CI — a reference recorded on runner hardware would then fail on every
developer's Mac. Do not skip the test: it is the only thing standing between a renderer
regression and a release.

**Sparkle reports a signature failure.** `SUPublicEDKey` in the shipped build and
`SPARKLE_PRIVATE_KEY` in the repository secrets are not a pair. Do not regenerate the key
to fix it: export the existing private key with `generate_keys -x` and correct the secret.

## Verifying a release by hand

```bash
# The download is signed by you, notarized, and carries its ticket offline.
codesign --verify --deep --strict --verbose=2 /Applications/Ketto.app
xcrun stapler validate /Applications/Ketto.app
spctl --assess --type execute --verbose=2 /Applications/Ketto.app

# The feed the app polls, and the signature it will check.
curl -sL https://github.com/boat-builder/ketto/releases/latest/download/appcast.xml
```
