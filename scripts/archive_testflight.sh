#!/bin/bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJECT_DIR"

: "${DEVELOPMENT_TEAM:?Set DEVELOPMENT_TEAM}" 
: "${APP_BUNDLE_ID:=com.core.githubautoupdater}"
: "${SCHEME:=GitHubAutoUpdaterApp}"
: "${CONFIGURATION:=Release}"
: "${ARCHIVE_PATH:=$PROJECT_DIR/build/GitHubAutoUpdaterApp.xcarchive}"
: "${EXPORT_PATH:=$PROJECT_DIR/build/export}"

mkdir -p "$PROJECT_DIR/build"

xcodegen generate
xcodebuild   -project GitHubAutoUpdaterApp.xcodeproj   -scheme "$SCHEME"   -configuration "$CONFIGURATION"   -destination 'generic/platform=iOS'   DEVELOPMENT_TEAM="$DEVELOPMENT_TEAM"   PRODUCT_BUNDLE_IDENTIFIER="$APP_BUNDLE_ID"   clean archive   -archivePath "$ARCHIVE_PATH"

cat > "$PROJECT_DIR/build/ExportOptions.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>method</key>
  <string>app-store-connect</string>
  <key>signingStyle</key>
  <string>automatic</string>
  <key>stripSwiftSymbols</key>
  <true/>
  <key>uploadSymbols</key>
  <true/>
</dict>
</plist>
PLIST

xcodebuild -exportArchive   -archivePath "$ARCHIVE_PATH"   -exportOptionsPlist "$PROJECT_DIR/build/ExportOptions.plist"   -exportPath "$EXPORT_PATH"

echo "Archive created at: $ARCHIVE_PATH"
echo "Export created at: $EXPORT_PATH"
echo "Upload with Xcode Organizer or iTMSTransporter / notary-compatible App Store tooling as preferred."
