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

say ""
say "Installed. Missing pieces:"
need flutter  || say "  - flutter is not on PATH"
need fastlane || say "  - fastlane is not installed (only needed for --upload): brew install fastlane"
say ""
say "Next:"
say "  1. Signing:  release signing /path/to/keystore.properties   (KEY_ALIAS, KEY_PATH, KEY_STORE_PASSWORD, KEY_PASSWORD)"
say "  2. Uploads:  fill in $DIR/fastlane/.env (App Store Connect key, Play service account)"
say "  3. In any Flutter app, run \`release\`"
