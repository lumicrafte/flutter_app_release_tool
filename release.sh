#!/usr/bin/env bash
# Production build for any Flutter app: bump the version in pubspec.yaml, build store artifacts,
# commit, tag, optionally upload. Run from inside a Flutter app; it reads the name and package from the project.
#
#   release signing <file>         remember the Android signing file (once per machine)
#   release                        interactive: asks each question in sequence
#   release patch|minor|major|build|current [--ios] [--android] [--upload] [--dry-run] [--no-tag] [--allow-dirty]
#
#   patch/minor/major  bump the version name and the build number
#   build              bump only the build number (re-upload after a rejected binary)
#   current            no bump: build another platform of the version already released
#   --ios / --android  build one platform (default: both)
#   --upload           push the artifacts with fastlane (lanes ios_upload / android_upload)
#   --dry-run          print the next version and the plan, change nothing
#   --no-tag           skip the release commit and tag
#   --allow-dirty      allow unrelated uncommitted changes (only pubspec.yaml is committed)

set -euo pipefail

die() { echo "error: $*" >&2; exit 1; }
step() { echo; echo "==> $*"; }

# The Android signing file is machine-level: remembered once in ~/.config/release-tools/config.
GLOBAL_CONFIG="$HOME/.config/release-tools/config"

# Warn when a secrets file can be read by other local users (macOS stat).
warn_loose() {
  local mode
  mode="$(stat -f %Lp "$1" 2>/dev/null || true)"
  if [ -n "$mode" ] && [ $((mode % 100)) -ne 0 ]; then
    echo "warning: $1 is readable by other users (mode $mode); run: chmod 600 \"$1\"" >&2
  fi
}

# Check the signing file has every key Gradle needs, and that the keystore it points to exists.
check_signing_file() {
  local key missing=""
  for key in KEY_ALIAS KEY_PATH KEY_STORE_PASSWORD KEY_PASSWORD; do
    grep -q "^$key=." "$1" || missing="$missing $key"
  done
  [ -z "$missing" ] || die "$1 is missing:$missing"
  local jks
  jks="$(sed -n 's/^KEY_PATH=//p' "$1" | head -n 1)"
  [ -f "$jks" ] || die "KEY_PATH in $1 is not a file: $jks"
  warn_loose "$1"
  warn_loose "$jks"
}

saved_signing_path() { sed -n 's/^KEYSTORE_PROPERTIES=//p' "$GLOBAL_CONFIG" 2>/dev/null | head -n 1 || true; }

save_signing_path() {
  local p="${1/#\~/$HOME}"
  [ -f "$p" ] || die "not a file: $p"
  p="$(cd "$(dirname "$p")" && pwd)/$(basename "$p")"
  mkdir -p "$(dirname "$GLOBAL_CONFIG")"
  printf 'KEYSTORE_PROPERTIES=%s\n' "$p" > "$GLOBAL_CONFIG"
  KEYSTORE_PROPERTIES="$p"
}

if [ "${1:-}" = "signing" ]; then
  save_signing_path "${2:?usage: release signing /path/to/keystore.properties}"
  echo "signing file saved: $KEYSTORE_PROPERTIES"
  exit 0
fi

# TOOLS_DIR is this repo (shared Fastfile, credentials). `release` is usually a symlink, so resolve it.
SELF="${BASH_SOURCE[0]}"
while [ -L "$SELF" ]; do
  LINK="$(readlink "$SELF")"
  case "$LINK" in /*) SELF="$LINK" ;; *) SELF="$(dirname "$SELF")/$LINK" ;; esac
done
TOOLS_DIR="$(cd "$(dirname "$SELF")" && pwd)"
FASTFILE="$TOOLS_DIR/fastlane/Fastfile"

# The app is the git repo we are run from.
ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" || die "run this from inside an app repository"
cd "$ROOT"
PUBSPEC="pubspec.yaml"
[ -f "$PUBSPEC" ] || die "no $PUBSPEC in $ROOT"

# Read what the project already says; release.config is only an optional override file.
ENV_SIGNING="${KEYSTORE_PROPERTIES:-}"
# shellcheck disable=SC1091
[ ! -f release.config ] || . ./release.config
: "${APP_NAME:=$(sed -nE 's/^name:[[:space:]]*([A-Za-z0-9_]+).*/\1/p' "$PUBSPEC" | head -n 1)}"
: "${ANDROID_PACKAGE:=$(sed -nE 's/.*applicationId[[:space:]]*=?[[:space:]]*"([^"]+)".*/\1/p' android/app/build.gradle.kts android/app/build.gradle 2>/dev/null | head -n 1 || true)}"
[ -n "$APP_NAME" ] || die "cannot read the app name from $PUBSPEC (set APP_NAME in release.config)"

# One signing key for every app. Order: environment, release.config, the remembered path.
# Exported so each app's Gradle build reads the same file.
KEYSTORE_PROPERTIES="${ENV_SIGNING:-${KEYSTORE_PROPERTIES:-$(saved_signing_path)}}"

# Find flutter when it is not on PATH (fvm or a plain checkout).
if ! command -v flutter >/dev/null; then
  for dir in "$HOME/fvm/default/bin" "$HOME/development/flutter/bin" "$HOME/flutter/bin"; do
    [ -x "$dir/flutter" ] && { export PATH="$dir:$PATH"; break; }
  done
fi

usage() { sed -n '2,15p' "$0" | sed 's/^# \{0,1\}//'; exit "${1:-0}"; }

# ---- current version --------------------------------------------------------
CURRENT="$(sed -nE 's/^version:[[:space:]]*([0-9]+\.[0-9]+\.[0-9]+\+[0-9]+)[[:space:]]*$/\1/p' "$PUBSPEC")"
[ -n "$CURRENT" ] || die "no 'version: X.Y.Z+N' line in $PUBSPEC"

NAME="${CURRENT%%+*}"
BUILD="${CURRENT##*+}"

# Prints the next version for a bump mode. The build number always grows and never resets,
# because store build numbers must only increase.
next_version() {
  local major minor patch
  IFS=. read -r major minor patch <<EOF2
$NAME
EOF2
  case "$1" in
    major) major=$((major + 1)); minor=0; patch=0 ;;
    minor) minor=$((minor + 1)); patch=0 ;;
    patch) patch=$((patch + 1)) ;;
  esac
  if [ "$1" = "current" ]; then echo "$CURRENT"; else echo "$major.$minor.$patch+$((BUILD + 1))"; fi
}

# ---- prompts ----------------------------------------------------------------
# choose "Question" DEFAULT_INDEX option... -> sets CHOICE (0-based). Arrow keys or j/k, enter to pick.
choose() {
  local title="$1" sel="$2" n i key rest
  shift 2
  local opts=("$@")
  n=${#opts[@]}
  draw() {
    for ((i = 0; i < n; i++)); do
      printf '\033[2K\r'
      if [ "$i" -eq "$sel" ]; then printf '  \033[36m●\033[0m %s\n' "${opts[$i]}"
      else printf '  \033[2m○ %s\033[0m\n' "${opts[$i]}"; fi
    done
  }
  printf '\033[36m◆\033[0m %s\n' "$title"
  draw
  while true; do
    IFS= read -rsn1 key || exit 1
    case "$key" in
      $'\033')
        read -rsn2 rest
        case "$rest" in
          '[A') sel=$(((sel + n - 1) % n)) ;;
          '[B') sel=$(((sel + 1) % n)) ;;
        esac ;;
      k) sel=$(((sel + n - 1) % n)) ;;
      j) sel=$(((sel + 1) % n)) ;;
      '') break ;;
      q) echo; exit 1 ;;
    esac
    printf '\033[%dA' "$n"
    draw
  done
  printf '\033[%dA\033[J' "$((n + 1))"
  printf '\033[32m✔\033[0m %s \033[2m%s\033[0m\n' "$title" "${opts[$sel]}"
  CHOICE=$sel
}

# ---- args -------------------------------------------------------------------
MODE=""
DO_IOS=0; DO_ANDROID=0
UPLOAD=0; DRY=0; TAG=1; DIRTY_OK=0
SET_PLATFORM=0; SET_UPLOAD=0; SET_TAG=0

for arg in "$@"; do
  case "$arg" in
    patch|minor|major|build|current) MODE="$arg" ;;
    --ios) DO_IOS=1; SET_PLATFORM=1 ;;
    --android) DO_ANDROID=1; SET_PLATFORM=1 ;;
    --upload) UPLOAD=1; SET_UPLOAD=1 ;;
    --dry-run) DRY=1 ;;
    --no-tag) TAG=0; SET_TAG=1 ;;
    --allow-dirty) DIRTY_OK=1 ;;
    -h|--help) usage 0 ;;
    *) echo "unknown argument: $arg" >&2; usage 1 ;;
  esac
done

# No bump type on the command line: ask, but only on a terminal.
if [ -z "$MODE" ]; then
  [ -t 0 ] || usage 1
  echo "Release $CURRENT"; echo
  choose "Version bump" 0 \
    "patch   $(next_version patch)" \
    "minor   $(next_version minor)" \
    "major   $(next_version major)" \
    "build   $(next_version build)  (build number only)" \
    "current $CURRENT  (same version, build another platform)"
  MODE="$(echo "patch minor major build current" | cut -d' ' -f$((CHOICE + 1)))"
  # A rebuild of the released version needs no new commit or tag.
  if [ "$MODE" = "current" ]; then TAG=0; SET_TAG=1; fi

  if [ "$SET_PLATFORM" = 0 ]; then
    choose "Platforms" 0 "iOS and Android" "iOS only" "Android only"
    case "$CHOICE" in
      0) DO_IOS=1; DO_ANDROID=1 ;;
      1) DO_IOS=1 ;;
      2) DO_ANDROID=1 ;;
    esac
  fi
  if [ "$SET_UPLOAD" = 0 ]; then
    choose "Upload to the stores after building?" 1 "Yes (TestFlight / Play $(grep -s '^PLAY_TRACK=' "$TOOLS_DIR/fastlane/.env" | cut -d= -f2- | grep . || echo internal))" "No, build only"
    [ "$CHOICE" = 0 ] && UPLOAD=1
  fi
  if [ "$SET_TAG" = 0 ]; then
    choose "Commit and tag the release?" 0 "Yes" "No"
    [ "$CHOICE" = 1 ] && TAG=0
  fi
  if [ -n "$(git status --porcelain)" ] && [ "$DIRTY_OK" = 0 ]; then
    choose "Working tree has uncommitted changes. Continue anyway?" 1 "No, stop" "Yes, release with them left out"
    [ "$CHOICE" = 0 ] && exit 1
    DIRTY_OK=1
  fi
  choose "Go?" 0 "Release now" "Dry run only" "Cancel"
  case "$CHOICE" in
    1) DRY=1 ;;
    2) exit 1 ;;
  esac
  echo
fi

if [ "$DO_IOS" = 0 ] && [ "$DO_ANDROID" = 0 ]; then DO_IOS=1; DO_ANDROID=1; fi
[ "$MODE" != "current" ] || TAG=0

NEXT="$(next_version "$MODE")"
NEXT_NAME="${NEXT%%+*}"
TAG_NAME="v$NEXT"
OUT_DIR="build/releases/$NEXT"

# ---- preflight --------------------------------------------------------------
if [ "$MODE" = "current" ]; then step "Rebuild $CURRENT (no version change)"; else step "Release $CURRENT -> $NEXT ($MODE)"; fi

BRANCH="$(git rev-parse --abbrev-ref HEAD)"
[ "$BRANCH" = "main" ] || echo "warning: on branch '$BRANCH', not main"

git diff --quiet -- "$PUBSPEC" && git diff --cached --quiet -- "$PUBSPEC" \
  || die "$PUBSPEC has uncommitted changes"
if [ "$DIRTY_OK" = 0 ] && [ -n "$(git status --porcelain)" ]; then
  die "working tree is not clean (commit or stash, or pass --allow-dirty)"
fi
if [ "$MODE" = "current" ]; then
  if git rev-parse -q --verify "refs/tags/$TAG_NAME" >/dev/null; then
    ahead="$(git rev-list --count "$TAG_NAME..HEAD")"
    [ "$ahead" = 0 ] || echo "warning: $ahead commit(s) since $TAG_NAME; this build will not match the earlier platform's code" >&2
  else
    echo "warning: no tag $TAG_NAME; was $CURRENT released from this code?" >&2
  fi
else
  git rev-parse -q --verify "refs/tags/$TAG_NAME" >/dev/null && die "tag $TAG_NAME already exists"
fi
command -v flutter >/dev/null || die "flutter not on PATH"
if [ "$DO_ANDROID" = 1 ]; then
  if [ ! -f "${KEYSTORE_PROPERTIES:-}" ]; then
    if [ "$DRY" = 1 ]; then
      echo "warning: Android signing file not set; run: release signing /path/to/keystore.properties" >&2
    else
      [ -t 0 ] || die "Android signing file not set; run: release signing /path/to/keystore.properties"
      [ -z "${KEYSTORE_PROPERTIES:-}" ] || echo "signing file not found: $KEYSTORE_PROPERTIES"
      printf 'Path to your keystore.properties (saved for every app): '
      read -r answer
      save_signing_path "$answer"
    fi
  fi
  if [ -f "${KEYSTORE_PROPERTIES:-}" ]; then
    check_signing_file "$KEYSTORE_PROPERTIES"
    export KEYSTORE_PROPERTIES
  fi
fi
if [ "$UPLOAD" = 1 ]; then
  command -v fastlane >/dev/null || die "--upload needs fastlane"
  [ -f "$FASTFILE" ] || die "--upload needs $FASTFILE"
fi

PLATFORMS=""
[ "$DO_IOS" = 1 ] && PLATFORMS="$PLATFORMS ios"
[ "$DO_ANDROID" = 1 ] && PLATFORMS="$PLATFORMS android"
echo "platforms:$PLATFORMS | upload: $UPLOAD | commit+tag: $TAG | artifacts: $OUT_DIR"

if [ "$DRY" = 1 ]; then
  echo; echo "dry run, nothing changed."
  exit 0
fi

# ---- quality gate -----------------------------------------------------------
step "flutter analyze"
flutter analyze
step "flutter test"
flutter test

# ---- bump (restored if anything below fails before the commit) --------------
BACKUP="$(mktemp)"
cp "$PUBSPEC" "$BACKUP"
COMMITTED=0
cleanup() {
  status=$?
  if [ "$status" -ne 0 ] && [ "$COMMITTED" = 0 ]; then
    cp "$BACKUP" "$PUBSPEC"
    echo "build failed, $PUBSPEC restored to $CURRENT" >&2
  fi
  rm -f "$BACKUP"
}
trap cleanup EXIT

if [ "$MODE" != "current" ]; then
  step "Set version $NEXT"
  sed -E -i '' "s/^version:.*/version: $NEXT/" "$PUBSPEC"
fi
flutter pub get >/dev/null

mkdir -p "$OUT_DIR"

# ---- build ------------------------------------------------------------------
IPA=""; AAB=""

if [ "$DO_IOS" = 1 ]; then
  step "Build iOS (ipa)"
  flutter build ipa --release
  IPA="$(ls -t build/ios/ipa/*.ipa 2>/dev/null | head -n 1 || true)"
  [ -n "$IPA" ] || die "no .ipa produced in build/ios/ipa"
  cp "$IPA" "$OUT_DIR/"
  IPA="$ROOT/$OUT_DIR/$(basename "$IPA")"
fi

if [ "$DO_ANDROID" = 1 ]; then
  step "Build Android (aab)"
  flutter build appbundle --release
  AAB="build/app/outputs/bundle/release/app-release.aab"
  [ -f "$AAB" ] || die "no .aab produced at $AAB"
  cp "$AAB" "$OUT_DIR/$APP_NAME-$NEXT.aab"
  AAB="$ROOT/$OUT_DIR/$APP_NAME-$NEXT.aab"
fi

# ---- commit + tag -----------------------------------------------------------
if [ "$TAG" = 1 ]; then
  step "Commit and tag $TAG_NAME"
  git add "$PUBSPEC"
  git commit -m "release: $NEXT" -- "$PUBSPEC"
  git tag "$TAG_NAME"
fi
COMMITTED=1

# ---- upload -----------------------------------------------------------------
if [ "$UPLOAD" = 1 ]; then
  if [ -n "$IPA" ]; then
    step "Upload iOS to TestFlight"
    IPA_PATH="$IPA" fastlane --fastfile "$FASTFILE" ios_upload \
      || echo "iOS upload failed; retry: IPA_PATH=$IPA fastlane --fastfile $FASTFILE ios_upload" >&2
  fi
  if [ -n "$AAB" ]; then
    step "Upload Android to Play"
    AAB_PATH="$AAB" ANDROID_PACKAGE="$ANDROID_PACKAGE" fastlane --fastfile "$FASTFILE" android_upload \
      || echo "Android upload failed; retry: AAB_PATH=$AAB ANDROID_PACKAGE=$ANDROID_PACKAGE fastlane --fastfile $FASTFILE android_upload" >&2
  fi
fi

# ---- summary ----------------------------------------------------------------
step "Done: $NEXT"
[ -n "$IPA" ] && echo "ipa: $IPA"
[ -n "$AAB" ] && echo "aab: $AAB"
[ "$TAG" = 1 ] && echo "push when ready: git push --follow-tags"
exit 0
