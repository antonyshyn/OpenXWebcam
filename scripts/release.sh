#!/bin/zsh
set -euo pipefail

cd "$(dirname "$0")/.."
version=$(sed -n 's/ *MARKETING_VERSION: "\(.*\)"/\1/p' Apps/OpenXWebcam/project.yml)
identity="Developer ID Application"
profile=openxwebcam
team=9F6WMC335W

cd Apps/OpenXWebcam
xcodegen generate
xcodebuild -project OpenXWebcam.xcodeproj -scheme OpenXWebcam -configuration Release \
    -derivedDataPath build \
    CODE_SIGNING_ALLOWED=NO \
    build
cd ../..

app=Apps/OpenXWebcam/build/Build/Products/Release/OpenXWebcam.app

rm -rf dist
mkdir -p dist/staging

sed "s/\$(TeamIdentifierPrefix)/$team./" Apps/OpenXWebcam/Extension/Extension.entitlements > dist/extension.entitlements
sed "s/\$(TeamIdentifierPrefix)/$team./" Apps/OpenXWebcam/App/App.entitlements > dist/app.entitlements
codesign --force --options runtime --timestamp --sign "$identity" \
    --entitlements dist/extension.entitlements \
    "$app/Contents/Library/SystemExtensions/com.openxwebcam.app.Extension.systemextension"
codesign --force --options runtime --timestamp --sign "$identity" \
    --entitlements dist/app.entitlements \
    "$app"
codesign --verify --strict --deep "$app"

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

rm -rf dist/staging dist/OpenXWebcam.zip dist/app.entitlements dist/extension.entitlements
echo "dist/OpenXWebcam-$version.dmg"
