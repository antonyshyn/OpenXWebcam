#!/bin/zsh
set -euo pipefail

cd "$(dirname "$0")/.."
version=$(sed -n 's/ *MARKETING_VERSION: "\(.*\)"/\1/p' Apps/OpenXWebcam/project.yml)
identity="Developer ID Application"
profile=openxwebcam

cd Apps/OpenXWebcam
xcodegen generate
xcodebuild archive -project OpenXWebcam.xcodeproj -scheme OpenXWebcam -configuration Release \
    -derivedDataPath build -archivePath build/OpenXWebcam.xcarchive \
    -allowProvisioningUpdates
xcodebuild -exportArchive -archivePath build/OpenXWebcam.xcarchive \
    -exportPath build/export -exportOptionsPlist ExportOptions.plist \
    -allowProvisioningUpdates
cd ../..

app=Apps/OpenXWebcam/build/export/OpenXWebcam.app
codesign --verify --strict --deep "$app"

rm -rf dist
mkdir -p dist/staging

ditto -c -k --keepParent "$app" dist/OpenXWebcam.zip
xcrun notarytool submit dist/OpenXWebcam.zip --keychain-profile "$profile" --wait
xcrun stapler staple "$app"

ditto "$app" dist/staging/OpenXWebcam.app
ln -s /Applications dist/staging/Applications
hdiutil create -volname OpenXWebcam -srcfolder dist/staging -ov -format UDZO "dist/OpenXWebcam-$version.dmg"
codesign --sign "$identity" --timestamp "dist/OpenXWebcam-$version.dmg"
xcrun notarytool submit "dist/OpenXWebcam-$version.dmg" --keychain-profile "$profile" --wait
xcrun stapler staple "dist/OpenXWebcam-$version.dmg"
spctl --assess --type open --context context:primary-signature "dist/OpenXWebcam-$version.dmg"

rm -rf dist/staging dist/OpenXWebcam.zip
echo "dist/OpenXWebcam-$version.dmg"
