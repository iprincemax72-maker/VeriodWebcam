#!/bin/sh
set -e
cd "$(dirname "$0")"
swift build -c release
A=build/Veriod.app
rm -rf "$A"; mkdir -p "$A/Contents/MacOS" "$A/Contents/Resources"
cp "$(swift build -c release --show-bin-path)/Veriod" "$A/Contents/MacOS/"
cp ../VeriodWebcam.icns "$A/Contents/Resources/Veriod.icns"
cat > "$A/Contents/Info.plist" <<P
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleName</key><string>Veriod</string>
<key>CFBundleIdentifier</key><string>com.veriod.mic</string>
<key>CFBundleExecutable</key><string>Veriod</string>
<key>CFBundleIconFile</key><string>Veriod</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>1.0</string>
<key>CFBundleVersion</key><string>1</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>NSHighResolutionCapable</key><true/>
<key>NSLocalNetworkUsageDescription</key><string>Veriod receives your phone's mic over Wi-Fi.</string>
<key>NSBonjourServices</key><array><string>_veriod._udp</string></array>
</dict></plist>
P
codesign --force --sign - "$A"
echo "built $A"
