# AGENTS.md

Instructions for AI coding agents (Codex, Cursor, Claude Code, Gemini CLI, Copilot and others). No PROMPT.md: this is a CLI filter, not a skill.

## Using this in your project

`fix-table-widths.lua` is a Pandoc Lua filter. It rewrites column widths of Markdown pipe tables from cell content instead of the separator row.

Run it when:
- a PDF or HTML build has a table whose prose column is cramped or overflows the page;
- the Markdown tables use minimal separators (`|---|---|`), which is what LLM-generated tables usually look like. Pandoc then splits the columns 50/50.

Call it:

```bash
pandoc input.md --lua-filter=fix-table-widths.lua -o output.pdf
```

Optional metadata (document front matter or `-M name=value`):
- `table-width-chars-full`: characters per full line width, a number above 10. Default 90.
- `table-width-abs-max-frac`: cap on any column minimum, 0.2 to 0.95. Default 0.55.

Exit codes are Pandoc's: 0 on success, non-zero on a Pandoc error. The filter itself never aborts a build; tables it cannot measure are left unchanged.

Never do the following:
- Do not edit the user's Markdown separator rows to fix widths; use the filter.
- Do not expect an effect on Markdown, GFM or other writers that ignore column widths.
- Do not claim a PDF is correct because the build exits 0. Check the rendered output; see pandoc-pdf-render-verify-kit.

## Working on this repo

- Test command: `make test` (needs `pandoc` 2.17 or newer on PATH; the script exits 2 with a message if it is missing).
- The test compares the `\real{...}` column fractions in LaTeX output with `tests/expected-widths.txt`, and checks that `table-width-chars-full` changes the result.
- Keep the filter a single file with no dependencies. Do not add network calls.
- Write only inside this repository. No absolute local paths in committed files.
