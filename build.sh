#!/bin/zsh
# 릴리스 빌드 후 build/KNoteTerm.app 번들 생성. ./build.sh install 이면 /Applications 로 복사.
set -e
cd "$(dirname "$0")"

# libghostty (터미널): 처음 한 번만 vendor/ghostty 소스로 빌드 (Zig 0.17 + Xcode Metal Toolchain 필요)
GK=vendor/ghostty/macos/GhosttyKit.xcframework
if [[ ! -d $GK ]]; then
  [[ -d vendor/ghostty ]] || git clone --depth 1 --branch v1.4.0 https://github.com/ghostty-org/ghostty.git vendor/ghostty
  [[ -x vendor/zig/zig ]] || { echo "vendor/zig/zig 필요 (https://ziglang.org/download 0.17.0)"; exit 1; }
  (cd vendor/ghostty && ../zig/zig build -Demit-xcframework=true -Dxcframework-target=native -Doptimize=ReleaseFast -Demit-macos-app=false)
fi

swift build -c release
APP=build/KNoteTerm.app
rm -rf $APP && mkdir -p $APP/Contents/MacOS
cp .build/release/KNoteTerm $APP/Contents/MacOS/
mkdir -p $APP/Contents/Resources && cp -R Resources/Fonts $APP/Contents/Resources/
cp Resources/AppIcon.icns $APP/Contents/Resources/
cp -R Resources/FileIcons $APP/Contents/Resources/   # 탐색기 아이콘 (Material Icon Theme, MIT)
# Ghostty 런타임 리소스: terminfo(xterm-ghostty) + 셸 통합(제목·작업폴더). 테마 폴더(3MB)는 생략
mkdir -p $APP/Contents/Resources/ghostty
cp -R vendor/ghostty/zig-out/share/terminfo $APP/Contents/Resources/
cp -R vendor/ghostty/zig-out/share/ghostty/shell-integration $APP/Contents/Resources/ghostty/
cat > $APP/Contents/Info.plist <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>KNoteTerm</string>
  <key>CFBundleIdentifier</key><string>local.knoteterm</string>
  <key>CFBundleExecutable</key><string>KNoteTerm</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>ATSApplicationFontsPath</key><string>Fonts</string>
  <key>NSDocumentsFolderUsageDescription</key><string>메모 저장 폴더(~/Documents/KNoteTerm)에 접근합니다.</string>
  <key>NSDesktopFolderUsageDescription</key><string>추가한 폴더의 파일을 열고 터미널에서 사용합니다.</string>
  <key>NSDownloadsFolderUsageDescription</key><string>추가한 폴더의 파일을 열고 터미널에서 사용합니다.</string>
  <key>CFBundleDocumentTypes</key><array><dict>
    <key>CFBundleTypeName</key><string>File</string>
    <key>CFBundleTypeRole</key><string>Viewer</string>
    <key>LSHandlerRank</key><string>Alternate</string>
    <key>LSItemContentTypes</key><array><string>public.item</string></array>
  </dict></array>
</dict></plist>
PLIST
codesign --force -s - $APP
[[ "$1" == install ]] && rm -rf /Applications/KNoteTerm.app && cp -R $APP /Applications/ && touch /Applications/KNoteTerm.app && echo "installed /Applications/KNoteTerm.app"
echo "built $APP"
