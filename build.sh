#!/bin/zsh
# Builds the receiver targets from the same core, no Xcode project:
#   ./build.sh          ->  noir-receiver (CLI)  +  Noir Receiver.app (menu bar)
#   ./build.sh cli      ->  CLI only
#   ./build.sh app      ->  app only
#   ./build.sh preview  ->  preview: measures the real views offscreen (see Preview.swift)
#   ./build.sh check    ->  eq-check: the mark's analyser against known signals (EqAnalyserCheck.swift)
#   ./build.sh app universal   ->  add `universal` to any of the above for an arm64 + x86_64 binary
#
# The .app bundle is assembled by hand: swiftc output + Info.plist. LSUIElement
# keeps it out of the Dock. Unsigned — fine locally and via a source-built brew
# formula; a downloaded copy needs Gatekeeper's Open Anyway once (see README).
set -e
cd ${0:A:h}

# **The minimum macOS, and the only place it is written.** Both the `-target` below and the
# bundle's LSMinimumSystemVersion come from here. Without the `-target`, swiftc checks API
# availability against the Mac doing the building — so the plist said 13.0 while the code
# used a macOS 14 `onChange`, and nothing said a word until 2026-09-04. A brew formula
# compiles on the *user's* Mac, so that is the machine such an error would have surfaced on.
MIN_OS=13.0

# The version is read out of the source rather than typed here again — `ReceiverVersion`
# in Receiver.swift is what the CLI prints and Settings shows, and the plist has to agree.
VERSION=$(sed -n 's/^public let ReceiverVersion = "\([^"]*\)".*/\1/p' Receiver.swift)
[[ -n $VERSION ]] || { print -u2 "could not read ReceiverVersion from Receiver.swift"; exit 1 }

# Every target compiles the core. The CLI is deliberately
# *not* given BlindsGlyph/BlindsEqMark/EqAnalyser: it has no menu bar, and the core
# reaches the analyser only through a closure it never sets.
CORE=(Protocol.swift Player.swift Session.swift Receiver.swift)
MARK=(BlindsGlyph.swift BlindsEqMark.swift EqAnalyser.swift)
# The status item's song and progress line: the app and the preview only, never the CLI or the check.
MENUBAR=(MenuBarItem.swift)
# The app's own files, behind its entry point (NoirReceiverMain.swift) or the preview's.
APPUI=(NoirReceiverApp.swift Preferences.swift ReceiverMenu.swift SettingsView.swift)

target=all
ARCHS=(arm64)
for arg in "$@"; do
  case $arg in
    all|cli|app|preview|check) target=$arg ;;
    # For a binary that rides on a release page. The brew path builds on the user's own
    # machine and does not need it, which is why the default is the host architecture only.
    universal) ARCHS=(arm64 x86_64) ;;
    *) print -u2 "unknown argument: $arg"; exit 2 ;;
  esac
done

# compile OUT SOURCES... — one swiftc per architecture, lipo'd together when there is more
# than one. Every invocation carries the `-target`, so an API above MIN_OS is a build error
# here rather than a crash on someone else's Mac.
compile() {
  local out=$1; shift
  local slices=()
  for arch in $ARCHS; do
    local slice=$out
    (( $#ARCHS > 1 )) && slice="$out.$arch"
    swiftc -O -parse-as-library -target ${arch}-apple-macos${MIN_OS} "$@" -o "$slice"
    slices+=("$slice")
  done
  if (( $#ARCHS > 1 )); then
    lipo -create "${slices[@]}" -output "$out"
    rm -f "${slices[@]}"
  fi
}

if [[ $target == all || $target == cli ]]; then
  compile noir-receiver $CORE NoirReceiverCLI.swift
  print "built noir-receiver $VERSION"
fi

# Same sources as the app, different @main — which is the whole reason the app's entry
# point lives alone in NoirReceiverMain.swift. Measures the real views, not copies.
if [[ $target == preview ]]; then
  compile preview $CORE $MARK $MENUBAR $APPUI Preview.swift
  print "built preview — run ./preview"
fi

# The analyser alone — no AppKit, no views, so it runs anywhere and needs no phone.
if [[ $target == all || $target == check ]]; then
  # `BlindsEqMark.swift` is in here so the check can compare the band count against the mark's own
  # slat count rather than a literal — which drags the core in with it, since `EqEngine`
  # takes a `Receiver`. Worth the compile: a literal is exactly what goes stale when the cut changes.
  compile eq-check $CORE $MARK EqAnalyserCheck.swift
  print "built eq-check — run ./eq-check"
fi

if [[ $target == all || $target == app ]]; then
  APP="Noir Receiver.app"
  # **Kill a running copy before rm -rf, or the build is invisible.** `open` on an already-running
  # app activates it rather than relaunching, and the old process happily keeps executing the
  # binary this is about to delete — so you get a fresh bundle on disk, a menu bar running code
  # from hours ago, and no error anywhere. That cost two rounds of "did you even update it" on
  # 2026-09-02, the second time four hours after writing the first one up. This is `dev.sh`'s
  # "never trust an install you did not verify" for the Mac half.
  if pkill -f "$APP/Contents/MacOS" 2>/dev/null; then
    print "stopped the running receiver (it would have kept the old binary alive)"
    sleep 1
  fi
  rm -rf "$APP"
  mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
  compile "$APP/Contents/MacOS/Noir Receiver" $CORE $MARK $MENUBAR $APPUI NoirReceiverMain.swift
  # A build tool, run here and never shipped: host architecture is all it needs.
  swiftc -O -parse-as-library BlindsGlyph.swift RenderIcon.swift -o render-icon
  ./render-icon
  mv AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
  BUILT_AT=$(date "+%H:%M:%S")
  # Unquoted heredoc on purpose: $VERSION and $MIN_OS are the two values this file must
  # not carry a second copy of. Nothing else in it expands.
  cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>      <string>Noir Receiver</string>
    <key>CFBundleIconFile</key>        <string>AppIcon</string>
    <key>CFBundleIdentifier</key>      <string>me.arsentsn.NoirReceiver</string>
    <key>CFBundleName</key>            <string>Noir Receiver</string>
    <key>CFBundlePackageType</key>     <string>APPL</string>
    <key>CFBundleShortVersionString</key> <string>$VERSION</string>
    <key>CFBundleVersion</key>         <string>$VERSION</string>
    <key>LSMinimumSystemVersion</key>  <string>$MIN_OS</string>
    <key>LSUIElement</key>             <true/>
    <!-- The text macOS 15's Local Network prompt shows, and the Bonjour type this app
         advertises, declared as Apple asks. Must match the type in Receiver.swift. -->
    <key>NSLocalNetworkUsageDescription</key>
    <string>Noir Receiver listens on your network so Noir Player on your phone can find this Mac and play through it.</string>
    <key>NSBonjourServices</key>       <array><string>_noirplayer._tcp</string></array>
</dict>
</plist>
PLIST
  # Ad-hoc signature over the *whole bundle*: the linker signs only the binary, leaving Info.plist
  # and the icon unsealed, so `codesign --verify` failed on every build. Ad-hoc is free and needs
  # no Apple account. It is not a Developer ID, so a browser-downloaded copy still meets
  # Gatekeeper; install.sh is the route that does not.
  codesign --force --sign - "$APP"
  # No backticks in this string: zsh runs them. The first version said "\`open\` alone will not"
  # and printed open(1)'s usage instead.
  print "built $APP $VERSION (${(j:+:)ARCHS}) at $BUILT_AT — relaunch it; open(1) alone will not"
fi
