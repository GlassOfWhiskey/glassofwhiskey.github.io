-- filters/cv_to_moderncv.lua
--
-- Pandoc Lua filter: converts YAML metadata into the body content of a
-- moderncv LaTeX document.  The companion template
-- (pandoc/templates/moderncv.latex) provides the preamble, personal info
-- commands, and the \begin{document}/\end{document} wrapper.
--
-- Source YAML files (each contains a single top-level key matching its name):
--   personal.yaml    → personal.{first,last,…,bio}
--   experience.yaml  → experience[…]
--   awards.yaml      → awards[…]
--   education.yaml   → education[…]
--   research.yaml    → research[…]
--   projects.yaml    → projects.{european,national}[…]
--   conferences.yaml → conferences.{chairs,committee,talks.{invited,regular}}[…]
--   software.yaml    → software[…]
--   editorial.yaml   → editorial[…]
--   review.yaml      → review.{projects,journals}[…]
--   teaching.yaml    → teaching.{courses,masters,schools,mentorships}[…]
--
-- Date fields in each entry use either:
--   year:  2026                    →  "2026"
--   start: 2023  /  end: present   →  "2023--present"
--
-- Inline Markdown supported in YAML string values:
--   `code`          → \texttt{code}
--   *emph*          → \emph{…}
--   **strong**      → \textbf{…}
--   ^super^         → \textsuperscript{…}
--   ~sub~           → \textsubscript{…}
--   "quoted text"   → ``quoted text'' (smart quotes via +smart extension)
--   €               → \euro{}
--   -- / ---        → -- / --- (en/em-dash roundtrip via smart extension)
--   & % #           → \& \% \#

-- ══════════════════════════════════════════════════════════════════════════
-- 1. Helpers
-- ══════════════════════════════════════════════════════════════════════════

--- Escape plain-text characters that have special meaning in LaTeX.
--- Called only on bare Str inline nodes; structural LaTeX is built
--- explicitly and never passed through this function.
local function esc(s)
  if type(s) ~= "string" then return "" end
  s = s:gsub("€",  "\\euro{}")
  s = s:gsub("\xE2\x80\x94", "---")   -- U+2014 em dash
  s = s:gsub("\xE2\x80\x93", "--")    -- U+2013 en dash
  s = s:gsub("&",  "\\&")
  s = s:gsub("%%", "\\%%")
  s = s:gsub("#",  "\\#")
  -- ^text^ → \textsuperscript{text}  (MetaString values from --metadata-file
  -- preserve the caret literally; MetaInlines use the Superscript inline node)
  s = s:gsub("%^(.-)%^", "\\textsuperscript{%1}")
  return s
end

--- Convert a list of Pandoc inline elements to a LaTeX string.
local function inlines_to_latex(inlines)
  local parts = {}
  for _, il in ipairs(inlines) do
    local t = il.t
    if     t == "Str"        then table.insert(parts, esc(il.text))
    elseif t == "Space"      then table.insert(parts, " ")
    elseif t == "SoftBreak"  then table.insert(parts, " ")
    elseif t == "LineBreak"  then table.insert(parts, "\\newline\n")
    elseif t == "Code"       then
      table.insert(parts, "\\texttt{" .. esc(il.text) .. "}")
    elseif t == "Emph"       then
      table.insert(parts, "\\emph{" .. inlines_to_latex(il.content) .. "}")
    elseif t == "Strong"     then
      table.insert(parts, "\\textbf{" .. inlines_to_latex(il.content) .. "}")
    elseif t == "Superscript" then
      table.insert(parts, "\\textsuperscript{" .. inlines_to_latex(il.content) .. "}")
    elseif t == "Subscript"  then
      table.insert(parts, "\\textsubscript{" .. inlines_to_latex(il.content) .. "}")
    elseif t == "Quoted"     then
      local inner = inlines_to_latex(il.content)
      if il.quotetype == "DoubleQuote" then
        table.insert(parts, "``" .. inner .. "''")
      else
        table.insert(parts, "`" .. inner .. "'")
      end
    elseif t == "RawInline" and il.format == "latex" then
      table.insert(parts, il.text)
    else
      -- Fallback: stringify and escape
      table.insert(parts, esc(pandoc.utils.stringify(il)))
    end
  end
  return table.concat(parts)
end

--- Convert a Pandoc MetaValue to a LaTeX string.
--- Handles both pandoc 3.x (Inlines/Blocks) and legacy (MetaInlines/MetaBlocks).
--- Paragraphs inside Blocks are joined with \newline (for \cventry args).
local function m(val)
  if val == nil then return "" end
  if type(val) == "string" then return esc(val) end
  local ptype = pandoc.utils.type(val)
  if ptype == "Inlines" then
    -- pandoc 3.x: MetaInlines is a plain Inlines sequence (no .content wrapper)
    return inlines_to_latex(val)
  elseif ptype == "Blocks" then
    -- pandoc 3.x: MetaBlocks is a plain Blocks sequence
    local paras = {}
    for _, blk in ipairs(val) do
      if blk.t == "Para" or blk.t == "Plain" then
        table.insert(paras, inlines_to_latex(blk.content))
      end
    end
    return table.concat(paras, "\\newline\n")
  else
    -- Legacy / fallback
    local t = val.t
    if     t == "MetaString"  then return esc(val.text or "")
    elseif t == "MetaInlines" then return inlines_to_latex(val.content)
    elseif t == "MetaBlocks"  then
      local paras = {}
      for _, blk in ipairs(val.content) do
        if blk.t == "Para" or blk.t == "Plain" then
          table.insert(paras, inlines_to_latex(blk.content))
        end
      end
      return table.concat(paras, "\\newline\n")
    else
      return esc(pandoc.utils.stringify(val))
    end
  end
end

--- Render the date field of an entry.
--- Supports:  year: 2026              →  "2026"
---            start: 2023 / end: …   →  "2023--…"
local function render_date(e)
  if e.year ~= nil then
    return m(e.year)
  elseif e.start ~= nil then
    local s  = m(e.start)
    local en = (e["end"] ~= nil) and m(e["end"]) or "present"
    return s .. "--" .. en
  end
  return ""
end

--- Render a list of years, collapsing contiguous runs into start--end ranges
--- and separating non-contiguous groups with ", ".
--- Accepts either integer calendar years or string academic years (e.g. "2022/2023").
--- For academic years, consecutive means the start of the next == end of the current
--- (i.e. start years differ by 1).
--- Examples:
---   {2020, 2024, 2025}                              → "2020, 2024--2025"
---   {"2022/2023", "2023/2024", "2024/2025"}         → "2022/2023--2024/2025"
---   {"2022/2023", "2024/2025"}                      → "2022/2023, 2024/2025"
local function render_years(years_val)
  if #years_val == 0 then return "" end
  local first_raw = m(years_val[1])
  if tonumber(first_raw) == nil then
    -- String academic years: sort by start year, collapse consecutive runs.
    local items = {}
    for _, y in ipairs(years_val) do
      local s = m(y)
      local start_yr = tonumber(string.match(s, "^(%d%d%d%d)")) or 0
      table.insert(items, { raw = s, start = start_yr })
    end
    table.sort(items, function(a, b) return a.start < b.start end)
    local groups = {}
    local i = 1
    while i <= #items do
      local j = i
      while j < #items and items[j + 1].start == items[j].start + 1 do
        j = j + 1
      end
      if j > i then
        table.insert(groups, items[i].raw .. "--" .. items[j].raw)
      else
        table.insert(groups, items[i].raw)
      end
      i = j + 1
    end
    return table.concat(groups, ", ")
  else
    -- Integer calendar years: existing range-collapse logic.
    local nums = {}
    for _, y in ipairs(years_val) do
      local n = tonumber(m(y))
      if n then table.insert(nums, n) end
    end
    table.sort(nums)
    local groups = {}
    local i = 1
    while i <= #nums do
      local j = i
      while j < #nums and nums[j + 1] == nums[j] + 1 do
        j = j + 1
      end
      if j > i then
        table.insert(groups, nums[i] .. "--" .. nums[j])
      else
        table.insert(groups, tostring(nums[i]))
      end
      i = j + 1
    end
    return table.concat(groups, ", ")
  end
end

--- Render the description field of a teaching entry.
--- Structured fields (modules / duration) are rendered first; if a free-form
--- description is also present it is appended after a \newline.
--- Priority order for the structured part:
---   modules list  →  duration string  →  (nothing)
--- If only description is present (no modules/duration), it is used as-is.
local function render_teaching_desc(e)
  local parts = {}
  if e.modules ~= nil then
    for _, mod in ipairs(e.modules) do
      local name_s = m(mod.name)
      local dur_s  = m(mod.duration)
      table.insert(parts, "Module ``" .. name_s .. ",'' " .. dur_s .. ".")
    end
  elseif e.duration ~= nil then
    table.insert(parts, m(e.duration) .. ".")
  end
  if e.description ~= nil then
    if #parts == 0 then
      return m(e.description)
    end
    table.insert(parts, m(e.description))
  end
  return table.concat(parts, "\\newline\n")
end

--- Extract a sortable integer key from an entry's date fields.
--- Ongoing entries (start with no end) always sort first (key = 9999).
--- Otherwise the maximum 4-digit year found in year/end fields is used.
local function sort_key(e)
  if e.start ~= nil and e["end"] == nil then
    local sy = tonumber(tostring(e.start):match("%d%d%d%d")) or 0
    return 99990000 + sy
  end
  local s = ""
  if e.year   ~= nil then s = s .. m(e.year) end
  if e["end"] ~= nil then s = s .. m(e["end"]) end
  if s == "" and e.start ~= nil then s = s .. m(e.start) end
  local max_y = 0
  for y in s:gmatch("%d%d%d%d") do
    local n = tonumber(y)
    if n and n > max_y then max_y = n end
  end
  return max_y
end

--- Return a copy of arr sorted by sort_key descending, then by start year
--- descending, then by original position (stable).
local function sort_desc(arr)
  local copy = {}
  for i, v in ipairs(arr) do table.insert(copy, {orig = i, val = v}) end
  table.sort(copy, function(a, b)
    local ka = sort_key(a.val)
    local kb = sort_key(b.val)
    if ka ~= kb then return ka > kb end
    local sa = tonumber(tostring(a.val.start):match("%d%d%d%d")) or 0
    local sb = tonumber(tostring(b.val.start):match("%d%d%d%d")) or 0
    if sa ~= sb then return sa > sb end
    return a.orig < b.orig
  end)
  local result = {}
  for _, item in ipairs(copy) do table.insert(result, item.val) end
  return result
end

--- Return a copy of arr sorted by max year in .years array descending.
--- Works for both integer calendar years and string academic years ("2022/2023").
--- For academic years the last 4-digit number (the end year) is used as the key.
local function sort_desc_committee(arr)
  local function max_year_in(e)
    local mx = 0
    if e.years ~= nil then
      for _, y in ipairs(e.years) do
        local s = m(y)
        local n = tonumber(s)
        if not n then
          -- Academic year string: use the last 4-digit number as the end year.
          local last = string.match(s, "(%d%d%d%d)$")
          if last then n = tonumber(last) end
        end
        if n and n > mx then mx = n end
      end
    end
    return mx
  end
  local copy = {}
  for _, v in ipairs(arr) do table.insert(copy, v) end
  table.sort(copy, function(a, b) return max_year_in(a) > max_year_in(b) end)
  return copy
end

--- Build a \cventry line from six positional fields.
local function cventry(f1, f2, f3, f4, f5, f6)
  return string.format("\\cventry{%s}{%s}{%s}{%s}{%s}{%s}",
    f1, f2, f3, f4 or "", f5 or "", f6 or "")
end

-- ══════════════════════════════════════════════════════════════════════════
-- 2. Main filter entry point  (generates body content only;
--    preamble and document structure live in templates/moderncv.latex)
-- ══════════════════════════════════════════════════════════════════════════

function Pandoc(doc)
  local meta = doc.meta
  local lines = {}

  local function L(s) table.insert(lines, s or "") end

  -- ── Biography ────────────────────────────────────────────────────────────
  L(m(meta.personal.bio))
  L("")

  -- ── Work experience ──────────────────────────────────────────────────────
  L("\\section{Work experience}")
  L("")
  for _, e in ipairs(sort_desc(meta.experience)) do
    L(cventry(render_date(e), m(e.title), m(e.org),
              m(e.location), "", m(e.description)))
    L("")
  end

  L("\\pagebreak")

  -- ── Honors and achievements ───────────────────────────────────────────────
  L("\\section{Honors and achievements}")
  L("")
  for _, e in ipairs(sort_desc(meta.awards)) do
    L(cventry(render_date(e), m(e.title), m(e.org),
              m(e.location), "", m(e.description)))
    L("")
  end

  -- ── Education ────────────────────────────────────────────────────────────
  L("\\section{Education}")
  L("")
  for _, e in ipairs(sort_desc(meta.education)) do
    L(cventry(render_date(e), m(e.title), m(e.org),
              "", m(e.grade), m(e.description)))
    L("")
  end

  L("\\pagebreak")

  -- ── Research activity ─────────────────────────────────────────────────────
  L("\\section{Research activity}")
  L("")
  for _, e in ipairs(sort_desc(meta.research)) do
    L(cventry(render_date(e), m(e.title), m(e.org), "", "", m(e.description)))
    L("")
  end

  -- ── Research projects ─────────────────────────────────────────────────────
  L("\\section{Research projects}")
  L("")
  L("\\subsection{European projects}")
  L("")
  local function project_desc(e)
    if e.achievement ~= nil then
      return "Main achievement. " .. m(e.achievement)
    end
    return m(e.description)
  end

  for _, e in ipairs(sort_desc(meta.projects.european)) do
    L(cventry(render_date(e), m(e.role), m(e.acronym),
              m(e.name), m(e.funding), project_desc(e)))
    L("")
  end
  L("\\subsection{National projects}")
  L("")
  for _, e in ipairs(sort_desc(meta.projects.national)) do
    L(cventry(render_date(e), m(e.role), m(e.acronym),
              m(e.name), m(e.funding), project_desc(e)))
    L("")
  end

  -- ── Scientific conferences ────────────────────────────────────────────────
  L("\\section{Scientific conferences}")
  L("")
  L("\\subsection{Service as a chairperson}")
  L("")
  for _, e in ipairs(sort_desc(meta.conferences.chairs)) do
    L(cventry(render_date(e), m(e.role), m(e.acronym),
              m(e.name), m(e.location), m(e.description)))
    L("")
  end
  L("\\subsection{Committee memberships}")
  L("")
  for _, e in ipairs(sort_desc_committee(meta.conferences.committee)) do
    L(cventry(render_years(e.years), "Program committee", m(e.acronym), m(e.name), "", ""))
    L("")
  end
  L("\\subsection{Invited talks}")
  L("")
  for _, e in ipairs(sort_desc(meta.conferences.talks.invited)) do
    L(cventry(render_date(e), m(e.role), m(e.acronym),
              m(e.name), m(e.location), ""))
    L("")
  end
  L("\\subsection{Regular talks}")
  L("")
  for _, e in ipairs(sort_desc(meta.conferences.talks.regular)) do
    local parts = { m(e.name) }
    if e.acronym ~= nil then
      table.insert(parts, "(" .. m(e.acronym) .. ")")
    end
    table.insert(parts, m(e.location) .. ".")
    L("\\cvlistitem{" .. table.concat(parts, " ") .. "}")
    L("")
  end

  -- ── Open source software ──────────────────────────────────────────────────
  L("\\section{Open source software}")
  L("")
  for _, e in ipairs(sort_desc(meta.software)) do
    L(cventry(render_date(e), m(e.title), m(e.role), "", "", m(e.description)))
    L("")
  end

  -- ── Editorial activity ────────────────────────────────────────────────────
  L("\\section{Editorial activity}")
  L("")
  for _, e in ipairs(sort_desc(meta.editorial)) do
    local desc = nil
    if e.issue ~= nil then desc = "Special Issue on " .. m(e.issue) end
    L(cventry(render_date(e), m(e.role), m(e.journal),
              m(e.publisher), "", desc))
    L("")
  end

  -- ── Review activity ───────────────────────────────────────────────────────
  L("\\section{Review activity}")
  L("")
  L("\\subsection{Research projects}")
  L("")
  for _, e in ipairs(sort_desc(meta.review.projects)) do
    L(cventry(render_date(e), m(e.title), "", "", "", m(e.description)))
    L("")
  end
  L("\\subsection{Scientific journals}")
  L("")
  for _, e in ipairs(meta.review.journals) do
    local parts = { m(e.title) }
    if e.editor ~= nil then table.insert(parts, m(e.editor)) end
    table.insert(parts, "ISSN " .. m(e.issn))
    L("\\cvlistitem{" .. table.concat(parts, ", ") .. ".}")
    L("")
  end

  -- ── Teaching activity ─────────────────────────────────────────────────────
  L("\\section{Teaching activity}")
  L("")
  L("\\subsection{Regular courses}")
  L("")
  for _, e in ipairs(sort_desc(meta.teaching.courses)) do
    L(cventry(render_date(e), m(e.role), m(e.course),
              m(e.institution), m(e.kind), render_teaching_desc(e)))
    L("")
  end
  L("\\subsection{Professional Master's programs}")
  L("")
  for _, e in ipairs(sort_desc_committee(meta.teaching.masters)) do
    L(cventry(render_years(e.years), m(e.role), m(e.program),
              m(e.institution), "", render_teaching_desc(e)))
    L("")
  end
  L("\\subsection{PhD summer/winter schools}")
  L("")
  for _, e in ipairs(sort_desc(meta.teaching.schools)) do
    L(cventry(render_date(e), m(e.role), m(e.program),
              m(e.institution), "", render_teaching_desc(e)))
    L("")
  end
  L("\\subsection{Mentorships}")
  L("")
  for _, e in ipairs(sort_desc(meta.teaching.mentorships)) do
    L(cventry(render_date(e), m(e.role), m(e.kind),
              m(e.topic), m(e.institution), ""))
    L("")
  end

  -- Emit the body as a single raw LaTeX block so Pandoc's writer makes no
  -- modifications whatsoever.  The template wraps this with the preamble,
  -- personal info commands, and \begin/\end{document}.
  local content = table.concat(lines, "\n")
  return pandoc.Pandoc({pandoc.RawBlock("latex", content)}, meta)
end
