#!/bin/zsh
# install.sh — install the "Toggle Terminal Panel" Finder Quick Action and hook
# finder-follow.zsh into ~/.zshrc. Everything else stays in this folder.
#
#   ./install.sh            interactive (asks before touching ~/.zshrc)
#   ./install.sh --yes      no questions
#   ./install.sh --no-zshrc skip the ~/.zshrc change
#
# Overrides: SERVICES_DIR (default ~/Library/Services), ZSHRC (default ~/.zshrc)

emulate -L zsh
setopt err_exit no_unset pipe_fail

HERE=${${(%):-%x}:A:h}
BIN="$HERE/bin/finder-terminal"
SNIPPET="$HERE/zsh/finder-follow.zsh"
TEMPLATE="$HERE/services/Toggle Terminal Panel.workflow"
SERVICES_DIR=${SERVICES_DIR:-$HOME/Library/Services}
ZSHRC=${ZSHRC:-$HOME/.zshrc}
MARK="# finder-terminal"
YES=0 DO_ZSHRC=1
for a in "$@"; do
  case $a in
    --yes|-y) YES=1 ;;
    --no-zshrc) DO_ZSHRC=0 ;;
    *) print -u2 "unknown option: $a"; exit 2 ;;
  esac
done

[[ -d /Applications/Ghostty.app || -d $HOME/Applications/Ghostty.app ]] || print -u2 "warning: Ghostty.app not found in /Applications or ~/Applications (set FINDER_TERMINAL_GHOSTTY)"

chmod +x "$BIN" "$HERE/uninstall.sh" "$HERE/install.sh"

# 1. Helper app (gets the Accessibility / Automation grants) --------------------
APP="$HERE/app/Finder Terminal.app"
APPLET_SRC="$HERE/app/finder-terminal-applet.applescript"
build_app() {
  local tmp="$HERE/app/.applet-build.applescript"
  local src=$(<"$APPLET_SRC")
  print -r -- "${src//__FINDER_TERMINAL_BIN__/$BIN}" > "$tmp"
  rm -rf "$APP"
  osacompile -o "$APP" "$tmp" 2>/dev/null
  rm -f "$tmp"
  plutil -replace CFBundleIdentifier -string "local.finder-terminal.helper" "$APP/Contents/Info.plist"
  plutil -replace CFBundleName -string "Finder Terminal" "$APP/Contents/Info.plist"
  plutil -replace LSUIElement -bool true "$APP/Contents/Info.plist"      # no Dock icon while it runs
  codesign --force --sign - "$APP" 2>/dev/null || true
  print -r -- "$BIN" > "$HERE/app/.built-for"
}
if [[ ! -d $APP ]] || [[ $APPLET_SRC -nt "$APP/Contents/Info.plist" ]] || [[ $(<"$HERE/app/.built-for" 2>/dev/null) != "$BIN" ]]; then
  build_app; print "built helper app: $APP"
else
  print "helper app up to date: $APP"
fi

# 1b. Event-driven watcher (optional, needs the Swift compiler from Xcode / Command Line Tools)
WATCH_SRC="$HERE/src/finder-terminal-watch.swift"
WATCH_BIN="$HERE/bin/finder-terminal-watch"
if xcrun --find swiftc >/dev/null 2>&1; then
  if [[ ! -x $WATCH_BIN || $WATCH_SRC -nt $WATCH_BIN ]]; then
    print -n "building event-driven watcher with swiftc... "
    if xcrun swiftc -O -o "$WATCH_BIN" "$WATCH_SRC" 2>"$HERE/bin/.swiftc.log"; then print "ok"; rm -f "$HERE/bin/.swiftc.log"
    else print "failed (see bin/.swiftc.log); falling back to the JXA watcher"; rm -f "$WATCH_BIN"; fi
  else
    print "event-driven watcher up to date: $WATCH_BIN"
  fi
else
  print "swiftc not found: using the polling JXA watcher (install Xcode Command Line Tools for the event-driven one)"
  rm -f "$WATCH_BIN"
fi

# 2. Quick Action -----------------------------------------------------------
xml_escape() { local s=$1; s=${s//\&/\&amp;}; s=${s//</\&lt;}; s=${s//>/\&gt;}; s=${s//\"/\&quot;}; print -r -- "$s"; }
DEST="$SERVICES_DIR/${TEMPLATE:t}"
mkdir -p "$DEST/Contents"
cp "$TEMPLATE/Contents/Info.plist" "$DEST/Contents/Info.plist"
local_wflow=$(<"$TEMPLATE/Contents/document.wflow")
print -r -- "${local_wflow//__FINDER_TERMINAL_APP__/$(xml_escape "$APP")}" > "$DEST/Contents/document.wflow"
plutil -lint "$DEST/Contents/Info.plist" "$DEST/Contents/document.wflow" >/dev/null
/System/Library/CoreServices/pbs -flush 2>/dev/null || true
/System/Library/CoreServices/pbs -update 2>/dev/null || true
print "installed Quick Action: $DEST"

# 3. ~/.zshrc ---------------------------------------------------------------
LINE="[[ -r \"$SNIPPET\" ]] && source \"$SNIPPET\"  $MARK"
if (( DO_ZSHRC )); then
  if [[ -f $ZSHRC ]] && grep -qF "$MARK" "$ZSHRC"; then
    print "~/.zshrc already sources finder-follow.zsh"
  else
    if (( ! YES )); then
      print -n "Append this line to $ZSHRC? [y/N] "
      print -r -- "  $LINE"
      read -q "reply?" || { print; print "skipped ~/.zshrc (add the line yourself, or re-run with --yes)"; DO_ZSHRC=0 }
      print
    fi
    if (( DO_ZSHRC )); then
      [[ -f $ZSHRC ]] && cp "$ZSHRC" "$ZSHRC.bak-finder-terminal"
      print -r -- "$LINE" >> "$ZSHRC"
      print "added to $ZSHRC (backup: $ZSHRC.bak-finder-terminal)"
    fi
  fi
fi

cat <<EOF

Done. Next steps
  1. Right-click a folder in Finder -> Quick Actions -> "Toggle Terminal Panel"
     (if it is not listed: Finder > Services > Services Settings... and tick it).
  2. Keyboard shortcut: System Settings > Keyboard > Keyboard Shortcuts... > Services
     > General > "Toggle Terminal Panel (Front Window)" -> double-click "none", press keys.
  3. The first run triggers macOS permission prompts for "Finder Terminal" (Automation
     for Finder, Ghostty and System Events; Accessibility). Allow them, then run the
     action again. If the windows overlap, Accessibility is still off: System Settings
     > Privacy & Security > Accessibility > enable "Finder Terminal".
     Details: $HERE/README.md

Manual use:  $BIN toggle|open|close|status
EOF
