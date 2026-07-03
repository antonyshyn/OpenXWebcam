# Contributing

Requirements: Xcode 26+, [xcodegen](https://github.com/yonaskolb/XcodeGen), and an
Apple Developer Program membership — the free tier can't sign system extensions.
Set `DEVELOPMENT_TEAM` in `Apps/OpenXWebcam/project.yml` to your team ID.

```sh
cd Apps/OpenXWebcam
xcodegen generate
xcodebuild -project OpenXWebcam.xcodeproj -scheme OpenXWebcam -configuration Release \
    -derivedDataPath build -allowProvisioningUpdates
ditto build/Build/Products/Release/OpenXWebcam.app /Applications/OpenXWebcam.app
open /Applications/OpenXWebcam.app
```

The app must run from /Applications. Approve the extension in
System Settings → General → Login Items & Extensions.

`CameraEngine/` is a plain Swift package: PTP transport, Fuji live-view protocol,
reconnect logic. `swift test` runs without hardware. Its CLI `openxwebcam-capture`
talks to a connected camera directly.

Extension gotchas:

- macOS only replaces an installed extension when `CFBundleVersion` changes —
  bump `CURRENT_PROJECT_VERSION` in project.yml for every extension change.
- launchd "error 37: Operation already in progress" after reinstall: bump the
  build number again and reinstall.
- Logs: `/usr/bin/log show --last 5m --predicate 'eventMessage CONTAINS "com.openxwebcam"'`

`scripts/release.sh` builds, signs, notarizes, and leaves a DMG in `dist/`.
Needs a Developer ID Application certificate and notarization credentials stored
via `xcrun notarytool store-credentials openxwebcam`.
