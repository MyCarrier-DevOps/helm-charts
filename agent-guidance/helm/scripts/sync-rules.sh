#!/usr/bin/env bash
# SessionStart hook for the helm plugin (native Claude Code plugin installs). Claude Code loads
# .claude/rules/**/*.md as path-scoped rules, but a plugin cannot ship rules, so this writes the package's APM
# instructions there: .apm/instructions/<name>.instructions.md -> .claude/rules/helm/<name>.md, with APM's applyTo
# turned into Claude's paths list. APM installs deploy the instruction themselves; this covers plugin installs.
# The plugin owns .claude/rules/helm/ outright: it prunes there and never touches other rules.
set -euo pipefail

NAME=helm
[ -n "${CLAUDE_PROJECT_DIR:-}" ] || exit 0
[ -n "${CLAUDE_PLUGIN_ROOT:-}" ] || exit 0
SRC="$CLAUDE_PLUGIN_ROOT/.apm/instructions"
DEST="$CLAUDE_PROJECT_DIR/.claude/rules/$NAME"
STAMP=".plugin-version"
# The plugin cache directory is named for the resolved version; under `claude --plugin-dir` it is the local dir name.
VERSION="$(basename "$CLAUDE_PLUGIN_ROOT")"

# to_rule <instruction>: the front matter's applyTo becomes paths (string or comma list split at top-level commas,
# brace alternation kept whole; a YAML list keeps its items). Everything else is copied unchanged.
to_rule() {
  awk -v sq="'" '
    function emit(s) { gsub(/^[[:space:]]+|[[:space:]]+$/, "", s); if (s != "") printf "  - \"%s\"\n", s }
    NR == 1 && $0 == "---" { fm = 1; print; next }
    fm && $0 == "---" { fm = 0; print; next }
    fm && /^applyTo:[[:space:]]*$/ { print "paths:"; next }
    fm && /^applyTo:/ {
      v = $0; sub(/^applyTo:[[:space:]]*/, "", v)
      first = substr(v, 1, 1)
      if ((first == "\"" || first == sq) && substr(v, length(v), 1) == first) v = substr(v, 2, length(v) - 2)
      print "paths:"
      depth = 0; item = ""
      for (i = 1; i <= length(v); i++) {
        ch = substr(v, i, 1)
        if (ch == "{") depth++
        if (ch == "}") depth--
        if (ch == "," && depth == 0) { emit(item); item = ""; continue }
        item = item ch
      }
      emit(item); next
    }
    { print }
  ' "$1"
}

# Both work directories sit next to the rules; whatever happens, neither may be left behind to load as rules.
STAGE="$DEST.staged.$$"
OLD="$DEST.old.$$"
trap 'rm -rf "$STAGE" "$OLD"' EXIT
rm -rf "$STAGE" "$OLD"
mkdir -p "$STAGE"
for f in "$SRC"/*.instructions.md; do
  [ -e "$f" ] || continue
  name=${f##*/}
  to_rule "$f" > "$STAGE/${name%.instructions.md}.md"
done

if ! ls "$STAGE"/*.md >/dev/null 2>&1 && [ ! -d "$DEST" ]; then
  exit 0
fi

same=1
for f in "$STAGE"/*.md "$DEST"/*.md; do
  [ -e "$f" ] || continue
  cmp -s "$STAGE/${f##*/}" "$DEST/${f##*/}" || same=0
done
if [ "$same" = 1 ] && [ "$(tail -n 1 "$DEST/$STAMP" 2>/dev/null)" = "$VERSION" ]; then
  exit 0
fi

{
  echo "# Plugin version that produced the rules in this directory ($NAME)."
  echo "# Written by sync-rules.sh -- do not edit."
  echo "$VERSION"
} > "$STAGE/$STAMP"

if [ -d "$DEST" ]; then
  mv "$DEST" "$OLD"
fi
mv "$STAGE" "$DEST"

COUNT=$(find "$DEST" -name '*.md' -type f | wc -l | tr -d ' ')
echo "$NAME: updated .claude/rules/$NAME/ ($COUNT rules, version $VERSION). The developer reviews and commits these files."
