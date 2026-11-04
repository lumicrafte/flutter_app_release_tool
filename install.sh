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

# What is still missing. Only names, formats and file existence are checked; no value is ever printed.
env_file="$DIR/fastlane/.env"
# The value of a key, as fastlane's .env loader sees it: no surrounding quotes, spaces or carriage return.
env_value() {
  sed -n "s/^$1=//p" "$env_file" 2>/dev/null | head -n 1 | tr -d '\r' \
    | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' -e 's/^"\(.*\)"$/\1/' -e "s/^'\\(.*\\)'\$/\\1/" || true
}

# Prints why a setting is not usable (nothing when it is fine). Formats Apple and Google use:
# key id = 10 capital letters or digits, issuer id = a UUID, key = an existing .p8, Play key = an existing .json.
setting_problem() {
  local key="$1" v ext="" key_id='^[A-Z0-9]{10}$' uuid='^[0-9a-fA-F]{8}(-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}$'
  v="$(env_value "$key")"
  [ -n "$v" ] || { echo "$key is empty"; return 0; }
  case "$key" in
    ASC_KEY_ID)         [[ "$v" =~ $key_id ]] || echo "$key should be 10 capital letters or digits" ;;
    ASC_ISSUER_ID)      [[ "$v" =~ $uuid ]] || echo "$key should be a UUID like 69a6de70-03db-47e3-e053-5b8c7c11a4d1" ;;
    ASC_KEY_PATH)       ext=p8 ;;
    PLAY_JSON_KEY_PATH) ext=json ;;
  esac
  if [ -n "$ext" ]; then
    if [ "${v##*.}" != "$ext" ]; then echo "$key should be a path ending in .$ext"
    elif [ ! -f "${v/#\~/$HOME}" ]; then echo "$key: there is no file at that path"; fi
  fi
}

todo=""
add() { todo="$todo$1"$'\n'; }

# One section of upload settings: silent about a store that was never set up, specific about a half-set one.
check_uploads() {                                    # $1 label, rest: the keys
  local label="$1" key v p set=0
  shift
  # A value that is still the placeholder from .env.example counts as not set.
  for key in "$@"; do
    v="$(env_value "$key")"
    [ -z "$v" ] || [ "$v" = "$(sed -n "s/^$key=//p" "$DIR/fastlane/.env.example" 2>/dev/null | head -n 1 || true)" ] || set=1
  done
  if [ "$set" = 0 ]; then local names="$*"; add "$label uploads (optional): not set up (${names// /, })"; return 0; fi
  for key in "$@"; do
    p="$(setting_problem "$key")"
    [ -z "$p" ] || add "$label uploads: $p"
  done
}

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

check_uploads iOS ASC_KEY_ID ASC_ISSUER_ID ASC_KEY_PATH
check_uploads Play PLAY_JSON_KEY_PATH

say ""
if [ -z "$todo" ]; then
  say "Installed, and everything is set up. In any Flutter app, run \`release\`."
else
  say "Installed. Still to do:"
  while IFS= read -r line; do [ -z "$line" ] || say "  - $line"; done <<<"$todo"
  case "$todo" in *uploads*) say ""; say "Upload settings live in $env_file" ;; esac
  say ""
  say "Then, in any Flutter app, run \`release\`."
fi
