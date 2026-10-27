#!/usr/bin/env bash
# Production builds for Flutter apps: bump the version, build the IPA and AAB, commit, upload.
# Run `release help` for usage. The help text lives in print_help below; keep it in sync with the code.

set -euo pipefail

die() { echo "error: $*" >&2; exit 1; }
step() { echo; echo "==> $*"; }

print_help() {
  cat <<'HELP'
release: build and ship a Flutter app to TestFlight and Google Play

USAGE
  release                          ask each question in turn
  release <bump> [options]         run without questions
  release clean [options]          delete old builds
  release signing <file>           remember the Android signing file
  release help                     show this help

BUMPS
  patch | minor | major    raise the version name and the build number
  build                    raise only the build number (after a rejected binary)
  current                  no bump: build another platform of the current version
  upload                   no build: upload what is already built for the current version

OPTIONS (builds and uploads)
  --ios, --android         one platform only (default: both; for `upload`, whatever was built)
  --upload                 upload to TestFlight / Play after building
  --dry-run                show the plan and change nothing
  --no-commit              leave the version bump uncommitted (default: commit pubspec.yaml)
  --tag                    tag the release commit as <app>/v<version> (default: no tag)
  --allow-dirty            allow unrelated uncommitted changes (only pubspec.yaml is committed)

CLEAN OPTIONS
  --keep N                 builds to keep, newest first (default: 3; the current version always stays)
  --dry-run                list what would be deleted
  --yes, -y                do not ask first

EXAMPLES
  release                              interactive release
  release patch --upload               patch release, upload both platforms
  release minor --android --tag        Android-only minor release, tagged
  release current --ios --upload       build and upload iOS for the version already released
  release upload                       retry an upload without rebuilding
  release clean --dry-run              see what old builds would be removed

FILES
  pubspec.yaml                         the version lives here (X.Y.Z+N); the app name comes from it
  android/app/build.gradle.kts         the Android package is read from applicationId
  release.config                       optional per-app overrides as KEY=value lines (read, not run):
                                       APP_NAME, ANDROID_PACKAGE, TAG_PREFIX, KEYSTORE_PROPERTIES
  ~/.config/release-tools/config       the signing file path, set once by `release signing`
  <install>/fastlane/.env              App Store Connect and Play credentials (see .env.example)
  build/releases/<version>/            the IPA and AAB of each release
HELP
}

# Help goes to stdout when asked for, to stderr when it follows an error.
usage() {
  if [ "${1:-0}" = 0 ]; then print_help; else print_help >&2; fi
  exit "${1:-0}"
}
case " ${1:-} " in " help " | " -h " | " --help ") usage 0 ;; esac
case " $* " in *" -h "* | *" --help "*) usage 0 ;; esac

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

# release.config holds plain KEY=value lines. It is read, never executed, so a repo cannot run code through it.
config_value() {
  [ -f release.config ] || return 0
  sed -n "s/^$1=//p" release.config | head -n 1 \
    | sed -e 's/^"\(.*\)"$/\1/' -e "s/^'\\(.*\\)'\$/\\1/" -e "s|^~|$HOME|" -e "s|^\\\$HOME|$HOME|"
}

# Read what the project already says; release.config only overrides.
ENV_SIGNING="${KEYSTORE_PROPERTIES:-}"
APP_NAME="$(config_value APP_NAME)"
ANDROID_PACKAGE="$(config_value ANDROID_PACKAGE)"
TAG_PREFIX="$(config_value TAG_PREFIX)"
CONFIG_SIGNING="$(config_value KEYSTORE_PROPERTIES)"
: "${APP_NAME:=$(sed -nE 's/^name:[[:space:]]*([A-Za-z0-9_]+).*/\1/p' "$PUBSPEC" | head -n 1)}"
: "${ANDROID_PACKAGE:=$(sed -nE 's/.*applicationId[[:space:]]*=?[[:space:]]*"([^"]+)".*/\1/p' android/app/build.gradle.kts android/app/build.gradle 2>/dev/null | head -n 1 || true)}"
: "${TAG_PREFIX:=${ANDROID_PACKAGE##*.}}"
: "${TAG_PREFIX:=$APP_NAME}"
[ -n "$APP_NAME" ] || die "cannot read the app name from $PUBSPEC (set APP_NAME in release.config)"

# One signing key for every app. Order: environment, release.config, the remembered path.
# Exported so each app's Gradle build reads the same file.
KEYSTORE_PROPERTIES="${ENV_SIGNING:-${CONFIG_SIGNING:-$(saved_signing_path)}}"

# Find flutter when it is not on PATH (fvm or a plain checkout).
if ! command -v flutter >/dev/null; then
  for dir in "$HOME/fvm/default/bin" "$HOME/development/flutter/bin" "$HOME/flutter/bin"; do
    [ -x "$dir/flutter" ] && { export PATH="$dir:$PATH"; break; }
  done
fi

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
  if [ "$1" = "current" ] || [ "$1" = "upload" ]; then echo "$CURRENT"; else echo "$major.$minor.$patch+$((BUILD + 1))"; fi
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

# ---- clean ------------------------------------------------------------------
# Removes old build/releases/<version>/ folders, newest build numbers kept. The version in
# pubspec.yaml is never removed, because `release current` and `release upload` use it.
if [ "${1:-}" = "clean" ]; then
  shift
  KEEP=3; ASSUME_YES=0; CLEAN_DRY=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --keep) KEEP="${2:?--keep needs a number}"; shift ;;
      --yes|-y) ASSUME_YES=1 ;;
      --dry-run) CLEAN_DRY=1 ;;
      *) die "unknown clean option: $1" ;;
    esac
    shift
  done
  case "$KEEP" in ''|*[!0-9]*) die "--keep must be a number" ;; esac

  REL_DIR="$ROOT/build/releases"
  [ -d "$REL_DIR" ] || { echo "nothing to clean: $REL_DIR does not exist"; exit 0; }

  # Newest first by build number (the part after +), which only ever grows.
  victims=(); seen=0; total_kb=0
  while IFS= read -r name; do
    seen=$((seen + 1))
    [ "$seen" -gt "$KEEP" ] || continue
    [ "$name" != "$CURRENT" ] || continue
    victims[${#victims[@]}]="$name"
  done < <(ls -1 "$REL_DIR" | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\+[0-9]+$' | sort -t+ -k2 -n -r)

  if [ "${#victims[@]}" -eq 0 ]; then
    echo "nothing to clean (keeping $KEEP, plus the current version $CURRENT)"
    exit 0
  fi
  for name in "${victims[@]}"; do
    kb="$(du -sk "$REL_DIR/$name" | cut -f1)"
    total_kb=$((total_kb + kb))
    printf '  %-14s %s\n' "$name" "$(du -sh "$REL_DIR/$name" | cut -f1)"
  done
  echo "$((${#victims[@]})) release(s), $((total_kb / 1024)) MB, in $REL_DIR"
  [ "$CLEAN_DRY" = 0 ] || { echo "dry run, nothing deleted."; exit 0; }

  if [ "$ASSUME_YES" = 0 ]; then
    [ -t 0 ] || die "not a terminal; pass --yes to delete"
    choose "Delete these ${#victims[@]} release(s)?" 0 "No, keep them" "Yes, delete"
    [ "$CHOICE" = 1 ] || exit 1
  fi
  for name in "${victims[@]}"; do rm -rf "${REL_DIR:?}/$name"; done
  echo "deleted ${#victims[@]} release(s)."
  exit 0
fi

# ---- args -------------------------------------------------------------------
MODE=""
DO_IOS=0; DO_ANDROID=0
UPLOAD=0; DRY=0; COMMIT=1; TAG=0; DIRTY_OK=0
SET_PLATFORM=0; SET_UPLOAD=0; SET_COMMIT=0; SET_TAG=0

for arg in "$@"; do
  case "$arg" in
    patch|minor|major|build|current|upload) MODE="$arg" ;;
    --ios) DO_IOS=1; SET_PLATFORM=1 ;;
    --android) DO_ANDROID=1; SET_PLATFORM=1 ;;
    --upload) UPLOAD=1; SET_UPLOAD=1 ;;
    --dry-run) DRY=1 ;;
    --no-commit) COMMIT=0; SET_COMMIT=1 ;;
    --tag) TAG=1; SET_TAG=1 ;;
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
    "current $CURRENT  (current version)" \
    "upload  $CURRENT  (upload the existing build, no rebuild)"
  MODE="$(echo "patch minor major build current upload" | cut -d' ' -f$((CHOICE + 1)))"
  # Rebuilding or uploading the current version changes nothing to commit or tag.
  if [ "$MODE" = "current" ] || [ "$MODE" = "upload" ]; then COMMIT=0; TAG=0; SET_COMMIT=1; SET_TAG=1; fi
  if [ "$MODE" = "upload" ]; then UPLOAD=1; SET_UPLOAD=1; fi

  if [ "$SET_PLATFORM" = 0 ]; then
    choose "Platforms" 0 "iOS and Android" "iOS only" "Android only"
    case "$CHOICE" in
      0) DO_IOS=1; DO_ANDROID=1 ;;
      1) DO_IOS=1; SET_PLATFORM=1 ;;
      2) DO_ANDROID=1; SET_PLATFORM=1 ;;
    esac
  fi
  if [ "$SET_UPLOAD" = 0 ]; then
    choose "Upload to the stores after building?" 1 "Yes (TestFlight / Play $(grep -s '^PLAY_TRACK=' "$TOOLS_DIR/fastlane/.env" | cut -d= -f2- | grep . || echo internal))" "No, build only"
    [ "$CHOICE" = 0 ] && UPLOAD=1
  fi
  if [ "$SET_COMMIT" = 0 ]; then
    choose "Commit the version bump?" 0 "Yes" "No"
    [ "$CHOICE" = 1 ] && COMMIT=0
  fi
  if [ "$SET_TAG" = 0 ] && [ "$COMMIT" = 1 ]; then
    choose "Tag the release commit?" 0 "No" "Yes ($TAG_PREFIX/v$(next_version "$MODE"))"
    [ "$CHOICE" = 1 ] && TAG=1
  fi
  if [ "$MODE" != "upload" ] && [ -n "$(git status --porcelain)" ] && [ "$DIRTY_OK" = 0 ]; then
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
if [ "$MODE" = "current" ] || [ "$MODE" = "upload" ]; then COMMIT=0; TAG=0; fi
[ "$MODE" != "upload" ] || UPLOAD=1
[ "$TAG" = 0 ] || [ "$COMMIT" = 1 ] || die "--tag needs the release commit (drop --no-commit)"

NEXT="$(next_version "$MODE")"
NEXT_NAME="${NEXT%%+*}"
TAG_NAME="$TAG_PREFIX/v$NEXT"
OUT_DIR="build/releases/$NEXT"

# ---- preflight --------------------------------------------------------------
if [ "$MODE" = "upload" ]; then step "Upload $CURRENT (no rebuild)"
elif [ "$MODE" = "current" ]; then step "Rebuild $CURRENT (no version change)"; else step "Release $CURRENT -> $NEXT ($MODE)"; fi

BRANCH="$(git rev-parse --abbrev-ref HEAD)"
[ "$BRANCH" = "main" ] || echo "warning: on branch '$BRANCH', not main"

# Uploading builds nothing and commits nothing, so the state of the tree does not matter for it.
if [ "$MODE" != "upload" ]; then
  git diff --quiet -- "$PUBSPEC" && git diff --cached --quiet -- "$PUBSPEC" \
    || die "$PUBSPEC has uncommitted changes"
  if [ "$DIRTY_OK" = 0 ] && [ -n "$(git status --porcelain)" ]; then
    die "working tree is not clean (commit or stash, or pass --allow-dirty)"
  fi
fi
if [ "$TAG" = 1 ] && git rev-parse -q --verify "refs/tags/$TAG_NAME" >/dev/null; then
  die "tag $TAG_NAME already exists"
fi
[ "$MODE" = "upload" ] || command -v flutter >/dev/null || die "flutter not on PATH"
if [ "$DO_ANDROID" = 1 ] && [ "$MODE" != "upload" ]; then
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

IPA=""; AAB=""
if [ "$MODE" = "upload" ]; then
  # Without --ios/--android, upload whichever platforms were built for this version.
  if [ "$DO_IOS" = 1 ]; then
    IPA="$(ls -t "$ROOT/$OUT_DIR"/*.ipa 2>/dev/null | head -n 1 || true)"
    [ -n "$IPA" ] || [ "$SET_PLATFORM" = 0 ] || die "no .ipa in $OUT_DIR (build it first: release current --ios)"
  fi
  if [ "$DO_ANDROID" = 1 ]; then
    AAB="$ROOT/$OUT_DIR/$APP_NAME-$NEXT.aab"
    if [ ! -f "$AAB" ]; then
      [ "$SET_PLATFORM" = 0 ] || die "no .aab at $AAB (build it first: release current --android)"
      AAB=""
    fi
  fi
  [ -n "$IPA$AAB" ] || die "nothing to upload in $OUT_DIR for $CURRENT"
fi

PLATFORMS=""
[ "$DO_IOS" = 1 ] && PLATFORMS="$PLATFORMS ios"
[ "$DO_ANDROID" = 1 ] && PLATFORMS="$PLATFORMS android"
echo "platforms:$PLATFORMS | upload: $UPLOAD | commit: $COMMIT | tag: $TAG | artifacts: $OUT_DIR"

if [ "$DRY" = 1 ]; then
  [ -z "$IPA" ] || echo "would upload: $IPA"
  [ -z "$AAB" ] || echo "would upload: $AAB"
  echo; echo "dry run, nothing changed."
  exit 0
fi

if [ "$MODE" != "upload" ]; then
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

fi

# ---- commit + tag -----------------------------------------------------------
if [ "$COMMIT" = 1 ]; then
  step "Commit $NEXT"
  git add "$PUBSPEC"
  git commit -m "release: $APP_NAME $NEXT" -- "$PUBSPEC"
  if [ "$TAG" = 1 ]; then
    git tag "$TAG_NAME"
    echo "tagged $TAG_NAME"
  fi
fi
COMMITTED=1

# ---- upload -----------------------------------------------------------------
# fastlane reads fastlane/Fastfile and fastlane/.env from the directory it runs in, so run it in this repo.
run_lane() {
  (cd "$TOOLS_DIR" && FASTLANE_SKIP_UPDATE_CHECK=1 FASTLANE_HIDE_CHANGELOG=1 FASTLANE_SKIP_DOCS=1 fastlane "$@")
}

UPLOAD_FAILED=0
if [ "$UPLOAD" = 1 ]; then
  if [ -n "$IPA" ]; then
    step "Upload iOS to TestFlight"
    IPA_PATH="$IPA" run_lane ios_upload \
      || { UPLOAD_FAILED=1; echo "iOS upload failed; retry: release upload --ios" >&2; }
  fi
  if [ -n "$AAB" ]; then
    step "Upload Android to Play"
    AAB_PATH="$AAB" ANDROID_PACKAGE="$ANDROID_PACKAGE" run_lane android_upload \
      || { UPLOAD_FAILED=1; echo "Android upload failed; retry: release upload --android" >&2; }
  fi
fi

# ---- summary ----------------------------------------------------------------
step "Done: $NEXT"
[ -n "$IPA" ] && echo "ipa: $IPA"
[ -n "$AAB" ] && echo "aab: $AAB"
[ "$COMMIT" = 1 ] && echo "push when ready: git push --follow-tags"
exit "$UPLOAD_FAILED"
