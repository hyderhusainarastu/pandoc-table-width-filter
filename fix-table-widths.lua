-- fix-table-widths.lua
--
-- Pandoc's default column-width heuristic for Markdown pipe tables that
-- don't carry explicit widths is based on the CHARACTER WIDTH OF THE HEADER
-- SEPARATOR ROW in the source (e.g. "---" vs "---:"), not on the actual
-- text content of the cells. A table written with minimal, uniform dashes
-- ("|---|---:|---:|---:|---|") for every column gets close to uniform
-- column widths no matter how lopsided the real content is -- a column of
-- long prose sentences can end up the same width as a column of short
-- numbers, or narrower.
--
-- That produces two classes of failure once the table reaches a fixed-width
-- output (PDF via LaTeX, or any writer that renders columns to a physical
-- page width):
--
--   1. A content-heavy column gets starved down to a tiny share of the
--      table width, so its cells wrap into many short lines -- rows that
--      overflow the page height, or badly broken paragraphs.
--   2. Fixing (1) with a naive "size columns proportional to character
--      count" pass introduces a new failure: short-but-wide-word columns
--      (e.g. a header label like "Component") get squeezed narrower than
--      their own longest unbreakable word, forcing an overfull line with
--      nowhere left to break.
--
-- Fix (this filter): recompute each table's column widths from actual
-- content, but respect a per-column MINIMUM width derived from the longest
-- unbreakable "atom" of text that column actually has to typeset (a run of
-- characters with no space or literal hyphen -- both are valid line-break
-- points; only these atoms can force an overfull line). Columns get at
-- least enough room for their longest atom (e.g. a word like "Component",
-- or a token like "v2.14.0-beta"), and the remaining width is distributed
-- proportionally to each column's total text volume via a standard
-- water-filling allocation (any column whose proportional share would fall
-- below its atom-derived minimum is pinned at that minimum first; the rest
-- split what's left). This is a general, content-aware replacement for
-- pandoc's separator-width heuristic that improves any table built with
-- uniform separator dashes, not just the ones that visibly break.

local CHARS_FULL = 90.0   -- rough characters-per-full-linewidth at 11pt Latin Modern
local ATOM_PAD = 2.0      -- small buffer so an atom isn't flush against cell padding
local ABS_MIN_FRAC = 0.045
local ABS_MAX_FRAC = 0.55

-- Optional overrides from document metadata (or `-M name=value` on the
-- command line). Invalid or out-of-range values are ignored.
--   table-width-chars-full    characters per full line width (number > 10)
--   table-width-abs-max-frac  cap on any column minimum, 0.2 to 0.95
local function meta_number(meta, key)
  local v = meta[key]
  if v == nil then return nil end
  local ok, s = pcall(pandoc.utils.stringify, v)
  if not ok then return nil end
  return tonumber(s)
end

local function read_meta(meta)
  local cf = meta_number(meta, "table-width-chars-full")
  if cf and cf > 10 then CHARS_FULL = cf end
  local mf = meta_number(meta, "table-width-abs-max-frac")
  if mf and mf >= 0.2 and mf <= 0.95 then ABS_MAX_FRAC = mf end
  return nil
end

local function cell_text(cell)
  local ok, s = pcall(pandoc.utils.stringify, cell.contents)
  if not ok or not s then return "" end
  return s
end

-- Longest run of characters with no space and no literal hyphen (both are
-- valid LaTeX/TeX break points in a raggedright paragraph column).
local function longest_atom_len(text)
  local maxlen = 0
  for atom in text:gmatch("[^%s%-]+") do
    local l = #atom
    if l > maxlen then maxlen = l end
  end
  return maxlen
end

-- pandoc.utils.stringify silently drops RawInline/RawBlock content (raw
-- format-specific markup embedded directly in a cell, e.g. a raw LaTeX
-- macro), so a cell containing ONLY such raw content would be measured as
-- empty text and starved down to the column-width floor. Fix: separately
-- walk each cell for raw nodes and add a length estimate (the letters in
-- the raw markup, plus a small constant for surrounding punctuation it
-- typically renders) so such columns get real width too.
local function raw_len_estimate(raw_text)
  local n = 0
  for word in raw_text:gmatch("%a+") do
    n = n + #word
  end
  return n + 2
end

local function raw_contribution(blocks)
  local total = 0
  local maxlen = 0
  local function note(el)
    local n = raw_len_estimate(el.text or "")
    total = total + n
    if n > maxlen then maxlen = n end
    return el
  end
  for _, blk in ipairs(blocks) do
    local ok = pcall(pandoc.walk_block, blk, {
      RawInline = note,
      RawBlock = note,
    })
    if not ok then
      -- Older/newer API mismatch: skip raw-length accounting for this
      -- block rather than failing the whole render.
    end
  end
  return total, maxlen
end

local function water_fill(weights, mins, n)
  local width = {}
  local active = {}
  local remaining_space = 1.0
  local remaining_weight = 0.0
  for i = 1, n do
    active[i] = true
    remaining_weight = remaining_weight + weights[i]
  end
  local changed = true
  while changed do
    changed = false
    local nactive = 0
    for i = 1, n do if active[i] then nactive = nactive + 1 end end
    if nactive == 0 then break end
    for i = 1, n do
      if active[i] then
        local proposed
        if remaining_weight > 1e-9 then
          proposed = weights[i] / remaining_weight * remaining_space
        else
          proposed = remaining_space / nactive
        end
        if proposed < mins[i] - 1e-9 then
          width[i] = mins[i]
          remaining_space = remaining_space - mins[i]
          remaining_weight = remaining_weight - weights[i]
          active[i] = false
          changed = true
        end
      end
    end
  end
  local nactive = 0
  for i = 1, n do if active[i] then nactive = nactive + 1 end end
  for i = 1, n do
    if active[i] then
      if remaining_weight > 1e-9 then
        width[i] = weights[i] / remaining_weight * math.max(remaining_space, 0)
      else
        width[i] = math.max(remaining_space, 0) / nactive
      end
    end
  end
  return width
end

local function Table(tbl)
  local ncols = #tbl.colspecs
  if ncols < 2 then return nil end

  local total_chars = {}
  local max_atom = {}
  for i = 1, ncols do
    total_chars[i] = 0
    max_atom[i] = 0
  end

  local function tally(row)
    for i, cell in ipairs(row.cells) do
      if i <= ncols then
        local text = cell_text(cell)
        local raw_total, raw_max = raw_contribution(cell.contents)
        total_chars[i] = total_chars[i] + #text + raw_total
        local a = longest_atom_len(text)
        if raw_max > a then a = raw_max end
        if a > max_atom[i] then max_atom[i] = a end
      end
    end
  end

  if tbl.head and tbl.head.rows then
    for _, row in ipairs(tbl.head.rows) do tally(row) end
  end
  for _, body in ipairs(tbl.bodies) do
    for _, row in ipairs(body.body) do tally(row) end
  end

  local grand_total = 0
  for i = 1, ncols do grand_total = grand_total + total_chars[i] end
  if grand_total <= 0 then return nil end

  -- Proportional weights from actual content volume (never zero, so every
  -- column can still receive leftover space in the water-fill pass).
  local weights = {}
  for i = 1, ncols do
    weights[i] = math.max(total_chars[i], 1)
  end

  -- Per-column minimum: enough for its longest unbreakable atom, clamped
  -- to a sane absolute range.
  local mins = {}
  local min_sum = 0
  for i = 1, ncols do
    local needed = (max_atom[i] + ATOM_PAD) / CHARS_FULL
    mins[i] = math.min(math.max(needed, ABS_MIN_FRAC), ABS_MAX_FRAC)
    min_sum = min_sum + mins[i]
  end
  -- Safety: if minimums alone would overflow the table width, scale them
  -- down proportionally (keeps 5% slack for the water-fill pass to work
  -- with) rather than producing an invalid/negative allocation.
  if min_sum > 0.95 then
    local scale = 0.95 / min_sum
    for i = 1, ncols do mins[i] = mins[i] * scale end
  end

  local fracs = water_fill(weights, mins, ncols)

  for i = 1, ncols do
    local align = tbl.colspecs[i][1]
    tbl.colspecs[i] = { align, fracs[i] }
  end

  return tbl
end

-- Two passes: metadata is read first, because Pandoc's default traversal
-- would otherwise visit Table elements before Meta.
return {
  { Meta = read_meta },
  { Table = Table },
}
