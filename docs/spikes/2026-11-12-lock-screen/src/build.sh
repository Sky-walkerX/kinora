#!/bin/zsh
# THROWAWAY SPIKE build: host app + com.apple.wallpaper extension, ad hoc signed.
set -euo pipefail
S=${0:A:h}; OUT=$S/build; APP=$OUT/LiveWallpaperSpike.app; EXT=$APP/Contents/Extensions/LiveWallpaperSpikeWallpaper.appex
rm -rf $OUT; mkdir -p $APP/Contents/MacOS $EXT/Contents/MacOS $EXT/Contents/Resources
swiftc -swift-version 5 -O -target arm64-apple-macos26.0 -parse-as-library $S/src/Extension.swift -o $EXT/Contents/MacOS/LiveWallpaperSpikeWallpaper -framework ExtensionFoundation -framework AVFoundation -framework QuartzCore -framework IOSurface -Xlinker -e -Xlinker _NSExtensionMain
swiftc -swift-version 5 -O -target arm64-apple-macos26.0 $S/src/Host.swift -o $APP/Contents/MacOS/LiveWallpaperSpike
cp ${VIDEO:-$S/assets/spike.mov} $EXT/Contents/Resources/spike.mov; cp ${THUMB:-$S/assets/thumb.png} $EXT/Contents/Resources/thumb.png
cat > $EXT/Contents/Info.plist <<PL
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>dev.spike.LiveWallpaperSpike.Wallpaper</string>
<key>CFBundleExecutable</key><string>LiveWallpaperSpikeWallpaper</string>
<key>CFBundleName</key><string>Live Wallpaper Spike</string>
<key>CFBundleDisplayName</key><string>Live Wallpaper Spike</string>
<key>CFBundlePackageType</key><string>XPC!</string>
<key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
<key>CFBundleShortVersionString</key><string>0.1</string>
<key>CFBundleVersion</key><string>1</string>
<key>LSMinimumSystemVersion</key><string>26.0</string>
<key>EXAppExtensionAttributes</key><dict><key>EXExtensionPointIdentifier</key><string>com.apple.wallpaper</string></dict>
</dict></plist>
PL
cat > $APP/Contents/Info.plist <<PL
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>dev.spike.LiveWallpaperSpike</string>
<key>CFBundleExecutable</key><string>LiveWallpaperSpike</string>
<key>CFBundleName</key><string>LiveWallpaperSpike</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
<key>CFBundleShortVersionString</key><string>0.1</string>
<key>CFBundleVersion</key><string>1</string>
<key>LSMinimumSystemVersion</key><string>26.0</string>
<key>LSUIElement</key><true/>
</dict></plist>
PL
cat > $OUT/ext.entitlements <<PL
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict><key>com.apple.security.app-sandbox</key><true/></dict></plist>
PL
codesign --force --sign - --entitlements $OUT/ext.entitlements --options runtime $EXT
codesign --force --sign - --options runtime $APP
codesign --verify --deep --strict $APP && echo "built + signed: $APP"
