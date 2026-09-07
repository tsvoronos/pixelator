#!/bin/zsh
# Builds Pixelator.app and installs the "Pixelate Image" Finder Quick Action.
# Requires Xcode Command Line Tools (swiftc). Nothing is downloaded.
#
#   ./install.sh              build app + install Quick Action
#   ./install.sh --app-only   skip the Quick Action
#   PIXELATOR_APP=/path/to/Pixelator.app ./install.sh    install somewhere specific

set -e

HERE="${0:A:h}"
SRC="$HERE/main.swift"
ICON="$HERE/assets/Pixelator.icns"
QA_SRC="$HERE/quickaction"
QA_DST="$HOME/Library/Services/Pixelate Image.workflow"
LSREG="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"

# Rebuild in place wherever Pixelator already lives, so moving it to
# /Applications doesn't leave a stale copy behind. Override with PIXELATOR_APP.
if [[ -n "$PIXELATOR_APP" ]]; then
  APP="$PIXELATOR_APP"
elif [[ -d "/Applications/Pixelator.app" ]]; then
  APP="/Applications/Pixelator.app"
else
  APP="$HOME/Applications/Pixelator.app"
fi

if [[ ! -f "$SRC" ]]; then
  echo "error: main.swift not found next to this script" >&2
  exit 1
fi

if ! command -v swiftc >/dev/null 2>&1; then
  echo "error: swiftc not found. Run: xcode-select --install" >&2
  exit 1
fi

# ---------------------------------------------------------------- the app

echo "Building $APP…"
mkdir -p "${APP:h}"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

swiftc -O -framework Cocoa "$SRC" -o "$APP/Contents/MacOS/Pixelator"

[[ -f "$ICON" ]] && cp "$ICON" "$APP/Contents/Resources/Pixelator.icns"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>            <string>Pixelator</string>
    <key>CFBundleDisplayName</key>     <string>Pixelator</string>
    <key>CFBundleExecutable</key>      <string>Pixelator</string>
    <key>CFBundleIdentifier</key>      <string>local.pixelator</string>
    <key>CFBundleVersion</key>         <string>1.0</string>
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>CFBundlePackageType</key>     <string>APPL</string>
    <key>CFBundleIconFile</key>        <string>Pixelator</string>
    <key>LSMinimumSystemVersion</key>  <string>11.0</string>
    <key>NSHighResolutionCapable</key> <true/>
    <key>LSApplicationCategoryType</key><string>public.app-category.graphics-design</string>

    <!-- Without this, macOS refuses to hand us a file at all: "Pixelator cannot
         open files in the PNG format." Rank Alternate so we don't take over as
         the default image handler from Preview. -->
    <key>CFBundleDocumentTypes</key>
    <array>
        <dict>
            <key>CFBundleTypeName</key>    <string>Image</string>
            <key>CFBundleTypeRole</key>    <string>Editor</string>
            <key>LSHandlerRank</key>       <string>Alternate</string>
            <key>LSItemContentTypes</key>
            <array>
                <string>public.image</string>
            </array>
        </dict>
    </array>
</dict>
</plist>
PLIST

# Ad-hoc sign so macOS treats it as a stable identity (avoids repeated
# permission prompts on later rebuilds).
codesign --force --deep --sign - "$APP" >/dev/null 2>&1 || true

# Register so the document types take effect and `open -b local.pixelator`
# resolves regardless of where the app lives.
[[ -x "$LSREG" ]] && "$LSREG" -f "$APP" >/dev/null 2>&1 || true

echo "  installed: $APP"

# ------------------------------------------------------- the Quick Action

if [[ "$1" == "--app-only" ]]; then
  echo
  echo "Skipped the Quick Action (--app-only)."
  exit 0
fi

if [[ -d "$QA_SRC" ]]; then
  echo "Installing Quick Action…"
  rm -rf "$QA_DST"
  mkdir -p "$QA_DST/Contents/Resources"
  cp "$QA_SRC/Info.plist"     "$QA_DST/Contents/Info.plist"
  cp "$QA_SRC/document.wflow" "$QA_DST/Contents/document.wflow"
  [[ -f "$QA_SRC/workflowCustomImage.png" ]] && \
    cp "$QA_SRC/workflowCustomImage.png" "$QA_DST/Contents/Resources/workflowCustomImage.png"

  [[ -x "$LSREG" ]] && "$LSREG" -f "$QA_DST" >/dev/null 2>&1 || true
  /System/Library/CoreServices/pbs -flush >/dev/null 2>&1 || true
  killall Finder >/dev/null 2>&1 || true

  echo "  installed: $QA_DST"
fi

cat <<EOF

Done.

  Right-click any image in Finder -> Quick Actions -> Pixelate Image
  Or:  Open With -> Pixelator
  Or:  open -n -b local.pixelator --args /path/to/some.png

First time you use it on a file in Desktop, Documents or Downloads, macOS
will ask permission to read that folder -- click Allow.
EOF
