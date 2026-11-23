#!/usr/bin/env bash
# Compares the per-column widths the filter writes into LaTeX output with
# tests/expected-widths.txt. Only the \real{...} fractions are compared, so
# the test does not depend on the exact LaTeX layout of one pandoc version.
set -eu
here=$(cd "$(dirname "$0")/.." && pwd)
if ! command -v pandoc >/dev/null 2>&1; then
  echo "pandoc not found; install pandoc 2.17 or newer to run this test" >&2
  exit 2
fi
widths() { grep -o '\\real{[0-9.]*}' | sed 's/\\real{\(.*\)}/\1/'; }
out=$(pandoc "$here/tests/wide-table.md" --lua-filter="$here/fix-table-widths.lua" -t latex | widths)
if [ "$out" != "$(cat "$here/tests/expected-widths.txt")" ]; then
  echo "FAIL: default widths differ from tests/expected-widths.txt" >&2
  echo "$out" >&2
  exit 1
fi
# Metadata override: a smaller CHARS_FULL makes the Component minimum larger.
alt=$(pandoc "$here/tests/wide-table.md" --lua-filter="$here/fix-table-widths.lua" \
  -M table-width-chars-full=45 -t latex | widths | head -1)
if [ "$alt" = "0.1222" ]; then
  echo "FAIL: table-width-chars-full had no effect" >&2
  exit 1
fi
echo "ok"
