#!/usr/bin/env bash
# Installs (or updates) release-tools and puts `release` on your PATH.
#   curl -fsSL https://raw.githubusercontent.com/lumicrafte/flutter_app_release_tool/main/install.sh | bash
set -euo pipefail

REPO="${RELEASE_TOOLS_REPO:-https://github.com/lumicrafte/flutter_app_release_tool.git}"
DIR="${RELEASE_TOOLS_HOME:-$HOME/.release-tools}"
BIN="${RELEASE_TOOLS_BIN:-$HOME/.local/bin}"

say() { printf '%s\n' "$*"; }
need() { command -v "$1" >/dev/null 2>&1; }

need git || { say "error: git is required"; exit 1; }

if [ -d "$DIR/.git" ]; then
  say "Updating $DIR"
  git -C "$DIR" pull --ff-only --quiet
else
  [ ! -e "$DIR" ] || { say "error: $DIR exists and is not a release-tools checkout"; exit 1; }
  say "Installing to $DIR"
  git clone --quiet "$REPO" "$DIR"
fi

chmod +x "$DIR/release.sh"
mkdir -p "$BIN"
ln -sf "$DIR/release.sh" "$BIN/release"

[ -f "$DIR/fastlane/.env" ] || cp "$DIR/fastlane/.env.example" "$DIR/fastlane/.env"

# Make sure the link is reachable from new terminals.
case ":$PATH:" in
  *":$BIN:"*) ;;
  *)
    case "${SHELL:-}" in */zsh) RC="$HOME/.zshrc" ;; */bash) RC="$HOME/.bashrc" ;; *) RC="" ;; esac
    if [ -n "$RC" ] && grep -qs '^# release-tools$' "$RC"; then
      say "PATH is already set in $RC (open a new terminal)"
    elif [ -n "$RC" ]; then
      printf '\n# release-tools\nexport PATH="%s:$PATH"\n' "$BIN" >> "$RC"
      say "Added $BIN to PATH in $RC (open a new terminal)"
    else
      say "Add $BIN to your PATH to use \`release\`"
    fi ;;
esac

# What is still missing. Only names and file existence are checked; no value is read out or printed.
env_file="$DIR/fastlane/.env"
# The value of a key, as fastlane's .env loader sees it: no surrounding quotes, no trailing carriage return.
env_value() {
  sed -n "s/^$1=//p" "$env_file" 2>/dev/null | head -n 1 | tr -d '\r' \
    | sed -e 's/^"\(.*\)"$/\1/' -e "s/^'\\(.*\\)'\$/\\1/" || true
}
env_has() { [ -n "$(env_value "$1")" ]; }                                       # key has a value
env_file_exists() {                                                              # key names a file that exists
  local v; v="$(env_value "$1")"
  [ -n "$v" ] && [ -f "${v/#\~/$HOME}" ]
}

todo=""
add() { todo="$todo$1"$'\n'; }

have_flutter=0
need flutter && have_flutter=1
for d in "$HOME/fvm/default/bin" "$HOME/development/flutter/bin" "$HOME/flutter/bin"; do
  [ -x "$d/flutter" ] && have_flutter=1
done
[ "$have_flutter" = 1 ] || add "flutter is not installed or not on PATH"
need fastlane || add "fastlane is not installed (only needed for uploads): brew install fastlane"

signing="$(sed -n 's/^KEYSTORE_PROPERTIES=//p' "$HOME/.config/release-tools/config" 2>/dev/null | head -n 1 || true)"
[ -n "$signing" ] && [ -f "$signing" ] \
  || add "Android signing: release signing /path/to/keystore.properties   (KEY_ALIAS, KEY_PATH, KEY_STORE_PASSWORD, KEY_PASSWORD)"

if ! { env_has ASC_KEY_ID && env_has ASC_ISSUER_ID && env_file_exists ASC_KEY_PATH; }; then
  add "iOS uploads (optional): set ASC_KEY_ID, ASC_ISSUER_ID and ASC_KEY_PATH in $env_file"
fi
env_file_exists PLAY_JSON_KEY_PATH || add "Play uploads (optional): set PLAY_JSON_KEY_PATH in $env_file"

say ""
if [ -z "$todo" ]; then
  say "Installed, and everything is set up. In any Flutter app, run \`release\`."
else
  say "Installed. Still to do:"
  while IFS= read -r line; do [ -z "$line" ] || say "  - $line"; done <<<"$todo"
  say ""
  say "Then, in any Flutter app, run \`release\`."
fi
