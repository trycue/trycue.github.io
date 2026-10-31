#!/bin/bash
# Cue installer.
#   Install:    curl -fsSL <install-url> | bash
#   Uninstall:  curl -fsSL <install-url> | bash -s -- --uninstall
#
# Installs for the current user only: no admin password, nothing outside your home folder
# except Cue.app in /Applications (when that folder is writable without sudo).
set -euo pipefail

# Filled in when a release is published. Tests point CUE_BASE_URL at a local server.
RELEASE_BASE_URL="https://trycue.github.io"
VERSION="1.0.3"

BASE_URL="${CUE_BASE_URL:-$RELEASE_BASE_URL}"
BUNDLE_ID="io.github.trycue.cue"
GUARDIAN_LABEL="io.github.trycue.cue.guardian"
MENUBAR_LABEL="io.github.trycue.cue.menubar"
DOMAIN="gui/$(id -u)"
AGENTS="$HOME/Library/LaunchAgents"
SUPPORT="$HOME/Library/Application Support/Cue"
LOGS="$HOME/Library/Logs/Cue"
TMP_DIR=""

say() { printf '%s\n' "$*"; }
ok() { printf '\033[32m✓\033[0m %s\n' "$*"; }
fail() { printf '\033[31m✗\033[0m %s\n' "$*" >&2; [ -n "${TMP_DIR:-}" ] && rm -rf "$TMP_DIR"; exit 1; }

# Only our own app bundle is ever replaced or removed.
is_cue() {
  [ -d "$1" ] && [ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$1/Contents/Info.plist" 2>/dev/null)" = "$BUNDLE_ID" ]
}

installed_app() {
  for dir in /Applications "$HOME/Applications"; do
    if is_cue "$dir/Cue.app"; then printf '%s\n' "$dir/Cue.app"; return 0; fi
  done
  return 1
}

stop_agents() {
  launchctl bootout "$DOMAIN/$MENUBAR_LABEL" 2>/dev/null || true
  launchctl bootout "$DOMAIN/$GUARDIAN_LABEL" 2>/dev/null || true
}

# Quits copies of Cue the user opened themselves (launchd doesn't know about those).
# Matches the exact executable path, never a pattern, and only this user's processes.
quit_running() {
  local exe pids
  for exe in "$1/Contents/MacOS/Cue" "$1/Contents/Helpers/cue-guardian"; do
    pids="$(ps -U "$(id -u)" -o pid=,comm= | EXE="$exe" awk '{ pid = $1; sub(/^ *[0-9]+ /, ""); if ($0 == ENVIRON["EXE"]) print pid }')"
    [ -n "$pids" ] && kill -TERM $pids 2>/dev/null || true
  done
  return 0
}

# Clears a saved "disabled" state (Settings → Open at login) without leaving a new record behind.
enable_if_disabled() {
  if launchctl print-disabled "$DOMAIN" 2>/dev/null | grep -qE "\"$1\" => (disabled|true)"; then
    launchctl enable "$DOMAIN/$1" 2>/dev/null || true
  fi
}

LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"

uninstall() {
  say "Removing Cue..."
  stop_agents
  rm -f "$AGENTS/$GUARDIAN_LABEL.plist" "$AGENTS/$MENUBAR_LABEL.plist"
  enable_if_disabled "$GUARDIAN_LABEL"
  enable_if_disabled "$MENUBAR_LABEL"
  for dir in /Applications "$HOME/Applications"; do
    if is_cue "$dir/Cue.app"; then
      quit_running "$dir/Cue.app"
      "$LSREGISTER" -u "$dir/Cue.app" 2>/dev/null || true
      rm -rf "$dir/Cue.app"
    fi
  done
  rm -rf "$SUPPORT" "$LOGS"
  # Files macOS creates for any app: preferences, caches, saved window state.
  defaults delete "$BUNDLE_ID" 2>/dev/null || true
  rm -rf "$HOME/Library/Preferences/$BUNDLE_ID.plist" \
         "$HOME/Library/Caches/$BUNDLE_ID" \
         "$HOME/Library/HTTPStorages/$BUNDLE_ID" "$HOME/Library/HTTPStorages/$BUNDLE_ID.binarycookies" \
         "$HOME/Library/Saved Application State/$BUNDLE_ID.savedState"
  local cache_dir
  cache_dir="$(getconf DARWIN_USER_CACHE_DIR 2>/dev/null || true)"
  [ -n "$cache_dir" ] && rm -rf "${cache_dir%/}/$BUNDLE_ID"
  ok "Cue has been removed."
}

xml_escape() {
  printf '%s' "$1" | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g' -e 's/"/\&quot;/g' -e "s/'/\&apos;/g"
}

write_agent() {
  local label="$1" program="$2" extra="$3"
  cat > "$AGENTS/$label.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Label</key><string>$label</string>
	<key>ProgramArguments</key><array><string>$(xml_escape "$program")</string></array>
	<key>AssociatedBundleIdentifiers</key><string>$BUNDLE_ID</string>
	<key>RunAtLoad</key><true/>
	<key>KeepAlive</key><dict><key>SuccessfulExit</key><false/></dict>
	<key>ProcessType</key><string>Interactive</string>
	<key>ThrottleInterval</key><integer>5</integer>
	<key>StandardOutPath</key><string>/dev/null</string>
$extra
</dict>
</plist>
PLIST
  chmod 644 "$AGENTS/$label.plist"
  plutil -lint -s "$AGENTS/$label.plist" || fail "Could not write $label.plist"
}

install() {
  [ "$(uname -s)" = "Darwin" ] || fail "Cue runs on macOS only."
  local major; major="$(sw_vers -productVersion | cut -d. -f1)"
  [ "$major" -ge 13 ] || fail "Cue needs macOS 13 Ventura or newer."
  [ "$(id -u)" -ne 0 ] || fail "Please run this without sudo. Cue installs for your user only."

  case "$BASE_URL" in
    https://*) ;;
    http://127.0.0.1:*|http://localhost:*) ;;  # local testing only
    __RELEASE_BASE_URL__) fail "This installer has no download address yet. Use the install command from the Cue website." ;;
    *) fail "Refusing to download from an insecure address: $BASE_URL" ;;
  esac

  local arch; arch="$(uname -m)"
  local zip="Cue-$VERSION-$arch.zip"
  # No EXIT trap: on macOS's bash 3.2 a trap can turn a failed install into exit status 0.
  # fail() and the end of install() remove the temporary folder instead.
  TMP_DIR="$(mktemp -d)"
  local tmp="$TMP_DIR"

  say "Installing Cue ${VERSION}..."
  curl -fsSL --proto '=https,http' --retry 2 -o "$tmp/$zip" "$BASE_URL/$zip" || fail "Download failed. Check your internet connection and try again."
  curl -fsSL --proto '=https,http' --retry 2 -o "$tmp/$zip.sha256" "$BASE_URL/$zip.sha256" || fail "Could not download the checksum."
  (cd "$tmp" && shasum -a 256 -c -s "$zip.sha256") || fail "The download is damaged (checksum mismatch). Please try again."
  ok "Downloaded Cue $VERSION"

  mkdir "$tmp/unpacked"
  ditto -x -k "$tmp/$zip" "$tmp/unpacked"
  local new="$tmp/unpacked/Cue.app"
  is_cue "$new" || fail "The download doesn't contain Cue."
  codesign --verify --strict "$new" 2>/dev/null || fail "Cue's code signature is invalid."

  local dest_dir="/Applications"
  [ -w "$dest_dir" ] || { dest_dir="$HOME/Applications"; mkdir -p "$dest_dir"; }
  local dest="$dest_dir/Cue.app"
  if [ -e "$dest" ] && ! is_cue "$dest"; then
    fail "$dest already exists and isn't Cue. Move it aside and try again."
  fi

  stop_agents
  [ -e "$dest" ] && quit_running "$dest"
  rm -rf "$dest"
  ditto "$new" "$dest"
  ok "Added to $dest_dir"

  mkdir -p "$AGENTS" "$LOGS"
  mkdir -p "$SUPPORT" && chmod 700 "$SUPPORT"
  write_agent "$GUARDIAN_LABEL" "$dest/Contents/Helpers/cue-guardian" \
    "	<key>StandardErrorPath</key><string>$(xml_escape "$LOGS/guardian.log")</string>"
  write_agent "$MENUBAR_LABEL" "$dest/Contents/MacOS/Cue" \
    "	<key>StandardErrorPath</key><string>/dev/null</string>
	<key>LimitLoadToSessionType</key><string>Aqua</string>"

  for label in "$GUARDIAN_LABEL" "$MENUBAR_LABEL"; do
    enable_if_disabled "$label"
    launchctl bootstrap "$DOMAIN" "$AGENTS/$label.plist" || fail "Could not start $label."
  done
  ok "Started the background guardian"
  ok "Set to open when you log in"
  rm -rf "$tmp"
  say ""
  say "Done. Look for the ring icon in your menu bar, at the top right of your screen."
}

case "${1:-}" in
  --uninstall) uninstall ;;
  "") install ;;
  *) fail "Unknown option: $1" ;;
esac
