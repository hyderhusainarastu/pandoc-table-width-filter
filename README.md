# pandoc-table-width-filter

A [Pandoc](https://pandoc.org/) Lua filter that fixes a specific, common defect in how Pandoc assigns column widths to Markdown pipe tables when it converts them to a fixed-width output (LaTeX/PDF, HTML, etc).

## The problem

For a Markdown pipe table that doesn't declare explicit column widths, Pandoc derives each column's width from the **character width of the header separator row** (the `---`, `---:`, `:---:` line under the header) — not from the actual text in the cells.

If every column in your table uses the same minimal dashes, like this:

```markdown
| Component | Status |
|---|---|
| Login | Done |
| Search Index | Rebuilding the ranking pipeline after the last schema change broke relevance scoring for multi-word queries; expect this to take another sprint before it is safe to re-enable in production. |
| Billing | Blocked on a vendor API key rotation that has been pending for three weeks. |
```

Pandoc gives both columns an equal 50/50 split, regardless of the fact that `Status` holds several sentences of prose and `Component` holds one short word per row. Converted to LaTeX, that comes out as:

```latex
>{\raggedright\arraybackslash}p{(\linewidth - 2\tabcolsep) * \real{0.5000}}
>{\raggedright\arraybackslash}p{(\linewidth - 2\tabcolsep) * \real{0.5000}}
```

In a PDF build this typically means the short column wastes half the page while the long column wraps into many extra lines — sometimes overflowing the page height entirely (`Overfull \vbox ... has occurred`).

The naive fix — size columns purely proportional to character count — creates a *different* bug: a short column with one long word (e.g. a header like `"Component"`) can get squeezed narrower than that single unbreakable word, producing an overfull line with no valid break point.

## The fix

`fix-table-widths.lua` recomputes each table's column widths from actual cell content, using a two-part algorithm:

1. **Per-column minimum**: each column is guaranteed enough width for its longest *unbreakable atom* — the longest run of characters with no space or hyphen, since those are the only two valid line-break points a typeset paragraph column can use. This stops a column from being squeezed narrower than its own longest word or token.
2. **Water-filling by content volume**: whatever width is left over after minimums are reserved is distributed across columns in proportion to their total text volume (character count, including raw markup passed through untouched by Pandoc's stringify step). Any column whose proportional share would fall below its minimum is pinned at the minimum first, and the remaining columns split what's left — a standard water-filling allocation.

Applied to the table above:

```latex
>{\raggedright\arraybackslash}p{(\linewidth - 2\tabcolsep) * \real{0.1222}}
>{\raggedright\arraybackslash}p{(\linewidth - 2\tabcolsep) * \real{0.8778}}
```

`Component` keeps just enough room for its own header word; `Status` gets the rest of the table for its prose.

## Works with

| Surface | How | Status |
|---|---|---|
| Pandoc CLI (LaTeX/PDF, HTML) | `--lua-filter` | not tested (no dated test run recorded) |
| AI coding agents (Codex, Cursor, Claude Code, Gemini CLI, Copilot) | read `AGENTS.md`, then run the CLI | not tested |

## Quick start

```bash
pandoc examples/wide-table.md --lua-filter=fix-table-widths.lua -t latex
```

Or as part of a normal PDF build:

```bash
pandoc report.md --lua-filter=fix-table-widths.lua -o report.pdf
```

The filter needs no configuration and no changes to your Markdown — it operates on any table Pandoc parses into its AST `Table` element, after the fact.

### Tuning with metadata

Two constants can be set from document metadata or the command line:

```bash
pandoc report.md --lua-filter=fix-table-widths.lua \
  -M table-width-chars-full=100 -M table-width-abs-max-frac=0.6 -o report.pdf
```

- `table-width-chars-full` (default `90`): characters per full line width. Raise it for a smaller font, lower it for a larger one.
- `table-width-abs-max-frac` (default `0.55`): the most width any column's minimum may claim, between 0.2 and 0.95.

Values outside those ranges, or non-numeric values, are ignored.

## LLM-generated tables

Language models almost always write pipe tables with the shortest separator, `|---|---|`. Pandoc reads that as equal separator widths and gives every column the same share, which is the 50/50 split shown above. Running this filter on such Markdown needs no change to the source.

## Use from an AI coding agent

Agents read [`AGENTS.md`](./AGENTS.md), which gives the exact command, the metadata options and what not to do. `CLAUDE.md`, `GEMINI.md` and `.github/copilot-instructions.md` point to it.

## Test

```bash
make test
```

This needs `pandoc` on PATH. It converts `tests/wide-table.md` to LaTeX and compares the column width fractions with `tests/expected-widths.txt`. Without pandoc it exits with a message and code 2.

## Limitations

- Only affects tables Pandoc represents with per-column width fractions (`ColWidth`) on the AST `Table` element. It is expected to take effect in the **LaTeX** writer (`-t latex`, and therefore any LaTeX-based PDF build) and the **HTML** writer (`-t html`), both of which render `colwidth` values; no dated test run is recorded for either. Writers that don't honor per-column widths — e.g. round-tripping back to Markdown/GFM (`-t gfm`, `-t markdown`) — silently ignore the change, so this filter has no visible effect on Markdown-to-Markdown conversions.
- Tables with only one column are left untouched (`return nil`), since there's nothing to redistribute.
- The character-based width estimate (`CHARS_FULL = 90` characters per full line width) is a rough heuristic tuned for an 11pt Latin Modern-style body font. If your document uses a very different font size or a monospace/CJK font, the resulting proportions will be less accurate — the algorithm will still avoid squeezing a column below its longest word, but the "prose volume" weighting may be off.
- Table captions, footnotes, and merged/spanning cells are not specially accounted for; the filter measures each cell's own text independently.
- This is a heuristic, not a proof: on pathological inputs (a single column holding an extremely long atom, e.g. a long unbroken URL or code token) the minimum-width safety clamp (`ABS_MAX_FRAC = 0.55`) can still leave a table looking uneven. It fixes the common case, not every case.

## How it differs

- **Pandoc's own column handling.** For a pipe table, Pandoc takes relative column widths from the dashes in the separator row, and only when some row is longer than the column limit. With the minimal `|---|---|` separator every column gets the same share. Nothing in core Pandoc looks at cell text to choose widths.
- **`--columns`.** This sets the line length in characters used for wrapping and for that long-row check. It does not change how the width shares are derived, so it cannot fix an equal split.
- **Editing the separator row by hand.** Adding dashes in proportion works, but it needs a change to every table in the source. This filter needs no change to the Markdown.
- **Other column-width Lua filters.** Filters that size columns purely in proportion to character count can squeeze a short column below its longest word. This one reserves each column's longest unbreakable run first and shares the remainder by content volume. I have not benchmarked it against specific other filters.

## How it works, briefly

See the comments in [`fix-table-widths.lua`](./fix-table-widths.lua) — the algorithm is a standard water-filling allocation: reserve each column's floor (its longest unbreakable text run), then distribute the rest proportionally to content volume, iterating until no active column's proportional share would violate its floor.

## Related

- [pandoc-pdf-render-verify-kit](https://github.com/hyderhusainarastu/pandoc-pdf-render-verify-kit): render Markdown to PDF and verify the result (page count, overlap, structure, LaTeX warnings) instead of trusting the exit code.

## Keywords

pandoc, lua filter, markdown pipe tables, column widths, LaTeX, PDF, HTML, LLM-generated tables

## License

MIT — see [LICENSE](./LICENSE).

---

Part of palimnote-tools - more at https://github.com/hyderhusainarastu
