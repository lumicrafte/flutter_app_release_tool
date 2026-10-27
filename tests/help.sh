#!/usr/bin/env bash
# Fails when release.sh accepts a flag, bump or command that `release help` does not mention.
set -euo pipefail

here="$(cd "$(dirname "$0")/.." && pwd)"
script="$here/release.sh"
help_text="$("$script" help)"

# Everything the argument parsers accept: flags (read from the case labels), the bump words, the subcommands.
accepted="$(
  {
    grep -E -- '^ +(-{1,2}[a-z][a-z-]*\|?)+\)' "$script" | grep -oE -- '-{1,2}[a-z][a-z-]*' | sort -u
    sed -n 's/^    \(patch|minor[^)]*\)).*/\1/p' "$script" | tr '|' '\n'
    printf '%s\n' clean signing help
  } | grep -vE -- '^(--help|-h)$' | sort -u
)"

missing=0
while IFS= read -r word; do
  [ -n "$word" ] || continue
  if ! grep -q -- "$word" <<<"$help_text"; then
    echo "help does not mention: $word"
    missing=1
  fi
done <<<"$accepted"

[ "$missing" = 0 ] && echo "help covers every flag, bump and command ($(wc -l <<<"$accepted" | tr -d ' ') checked)"
exit "$missing"
