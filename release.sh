#!/usr/bin/env bash
# Production build for any Flutter app: bump the version in pubspec.yaml, build store artifacts,
# commit, tag, optionally upload. Run from inside an app that has a release.config.
#
#   release.sh                     interactive: asks each question in sequence
#   release.sh patch|minor|major|build [--ios] [--android] [--upload] [--dry-run] [--no-tag] [--allow-dirty]
#
#   patch/minor/major  bump the version name and the build number
#   build              bump only the build number (re-upload after a rejected binary)
#   --ios / --android  build one platform (default: both)
#   --upload           push the artifacts with fastlane (lanes ios_upload / android_upload)
#   --dry-run          print the next version and the plan, change nothing
#   --no-tag           skip the release commit and tag
#   --allow-dirty      allow unrelated uncommitted changes (only pubspec.yaml is committed)

set -euo pipefail

die() { echo "error: $*" >&2; exit 1; }
step() { echo; echo "==> $*"; }

# TOOLS_DIR is this repo (shared Fastfile, credentials); the app is the git repo we are run from.
TOOLS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" || die "run this from inside an app repository"
cd "$ROOT"

PUBSPEC="pubspec.yaml"
[ -f "$PUBSPEC" ] || die "no $PUBSPEC in $ROOT"
[ -f release.config ] || die "no release.config in $ROOT (needs APP_NAME and ANDROID_PACKAGE)"
# shellcheck disable=SC1091
. ./release.config
: "${APP_NAME:?release.config must set APP_NAME}"
: "${ANDROID_PACKAGE:?release.config must set ANDROID_PACKAGE}"

# One signing key for every app (see android/app/build.gradle.kts in each app).
KEYSTORE_PROPERTIES="${KEYSTORE_PROPERTIES:-$HOME/Desktop/ltl/keystore.properties}"
FASTFILE="$TOOLS_DIR/fastlane/Fastfile"

# flutter lives in fvm on this machine
command -v flutter >/dev/null || { [ -d "$HOME/fvm/default/bin" ] && export PATH="$HOME/fvm/default/bin:$PATH"; }

usage() { sed -n '2,13p' "$0" | sed 's/^# \{0,1\}//'; exit "${1:-0}"; }

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
  echo "$major.$minor.$patch+$((BUILD + 1))"
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
    patch|minor|major|build) MODE="$arg" ;;
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
    "build   $(next_version build)  (build number only)"
  MODE="$(echo "patch minor major build" | cut -d' ' -f$((CHOICE + 1)))"

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

NEXT="$(next_version "$MODE")"
NEXT_NAME="${NEXT%%+*}"
TAG_NAME="v$NEXT"
OUT_DIR="build/releases/$NEXT"

# ---- preflight --------------------------------------------------------------
step "Release $CURRENT -> $NEXT ($MODE)"

BRANCH="$(git rev-parse --abbrev-ref HEAD)"
[ "$BRANCH" = "main" ] || echo "warning: on branch '$BRANCH', not main"

git diff --quiet -- "$PUBSPEC" && git diff --cached --quiet -- "$PUBSPEC" \
  || die "$PUBSPEC has uncommitted changes"
if [ "$DIRTY_OK" = 0 ] && [ -n "$(git status --porcelain)" ]; then
  die "working tree is not clean (commit or stash, or pass --allow-dirty)"
fi
git rev-parse -q --verify "refs/tags/$TAG_NAME" >/dev/null && die "tag $TAG_NAME already exists"
command -v flutter >/dev/null || die "flutter not on PATH"
if [ "$DO_ANDROID" = 1 ]; then
  [ -f "$KEYSTORE_PROPERTIES" ] || die "Android signing file not found: $KEYSTORE_PROPERTIES"
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

step "Set version $NEXT"
sed -E -i '' "s/^version:.*/version: $NEXT/" "$PUBSPEC"
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
