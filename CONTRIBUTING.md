# Contributing

## Building

Requirements: Xcode 26+, [xcodegen](https://github.com/yonaskolb/XcodeGen), and an
Apple Developer Program membership — the free tier can't sign system extensions.
Set `DEVELOPMENT_TEAM` in `Apps/OpenXWebcam/project.yml` to your team ID.

```sh
cd Apps/OpenXWebcam
xcodegen generate
xcodebuild -project OpenXWebcam.xcodeproj -scheme OpenXWebcam -configuration Release \
    -derivedDataPath build -allowProvisioningUpdates
```

The app must run from /Applications for the extension to activate:

```sh
ditto Apps/OpenXWebcam/build/Build/Products/Release/OpenXWebcam.app /Applications/OpenXWebcam.app
open /Applications/OpenXWebcam.app
```

Approve the extension in System Settings → General → Login Items & Extensions.

## Engine

`CameraEngine/` is a plain Swift package: the USB PTP transport, the Fuji live-view
protocol, and the reconnect state machine. `swift test` runs without hardware.

`openxwebcam-capture`, the package's CLI, talks to a connected camera directly —
`stream`, `watch`, `props`, `getprop`, `setprop` — useful for protocol work without
involving the app or the extension.

## Camera extension gotchas

Things that cost hours; check them before debugging anything else:

- sysextd only replaces an installed extension when `CFBundleVersion` changes.
  Bump `CURRENT_PROJECT_VERSION` in project.yml for every extension change, or
  macOS silently keeps running the old copy.
- Even with a version bump, launchd sometimes rejects the new extension with
  "error 37: Operation already in progress" while the old job is still tearing
  down. The extension then shows `[activated enabled]` in `systemextensionsctl list`
  but no process runs and the virtual camera disappears. Fix: bump the build
  number again and reinstall.
- `CFBundlePackageType` must be `SYSX`. xcodegen doesn't set it for
  system-extension targets, and activation fails with "does not appear to belong
  to any extension categories" without it.
- `CODE_SIGN_INJECT_BASE_ENTITLEMENTS: NO` is required — a get-task-allow
  entitlement on the extension fails category validation.
- App and extension must share an application group
  (`$(TeamIdentifierPrefix)com.openxwebcam`).
- The extension runs as `_cmiodalassistants` under the job label
  `CMIOExtension.com.openxwebcam.app.Extension`. Logs:
  `/usr/bin/log show --last 5m --predicate 'eventMessage CONTAINS "com.openxwebcam"'`
  (`log` alone is a zsh builtin — spell out `/usr/bin/log`).

## Releasing

`scripts/release.sh` builds, signs with Developer ID, notarizes, staples, and
leaves a DMG in `dist/`. One-time setup:

- Developer ID Application certificate: Xcode → Settings → Accounts →
  Manage Certificates → + → Developer ID Application.
- Notarization credentials:
  `xcrun notarytool store-credentials openxwebcam --apple-id <apple-id> --team-id <team-id> --password <app-specific-password>`
  (create the app-specific password at appleid.apple.com).
