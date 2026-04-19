-- Pretty-printing and normalization for Confluence storage-format XHTML.
--
-- Confluence v2 returns page bodies as a single line with no whitespace
-- between block elements and with `local-id="<uuid>"` attributes on most
-- nodes (used by the collaborative editor; safe to drop — the server will
-- regenerate them on save).
--
-- This module provides:
--   pretty(xhtml)   → multi-line, indented, local-id-stripped string for editing
--   compact(xhtml)  → single-line string with leading/trailing whitespace
--                     trimmed inside tags, suitable for sending back to the API
--
-- We deliberately use simple regex-based passes rather than a real XML parser:
-- storage format is XHTML-ish but not strictly well-formed (it embeds custom
-- `ac:` and `ri:` macro tags), and a tolerant text-pass survives those without
-- needing an external dependency.

local M = {}

-- Tags whose opening tag should sit on its own line.
-- Keep in sync with Confluence's block-level storage elements.
local BLOCK_OPEN = {
  'p', 'h1', 'h2', 'h3', 'h4', 'h5', 'h6',
  'ul', 'ol', 'li',
  'table', 'thead', 'tbody', 'tr', 'th', 'td', 'colgroup', 'col',
  'blockquote', 'pre', 'div', 'hr',
  'ac:structured%-macro', 'ac:rich%-text%-body', 'ac:plain%-text%-body',
  'ac:parameter', 'ac:layout', 'ac:layout%-section', 'ac:layout%-cell',
  'ac:task%-list', 'ac:task', 'ac:task%-id', 'ac:task%-status', 'ac:task%-body',
  'ac:image', 'ac:link',
}

--- Strip Confluence's `local-id="..."` attributes from every tag.
local function strip_local_ids(s)
  -- Match ` local-id="..."` (with optional preceding whitespace) anywhere.
  return (s:gsub('%s+local%-id="[^"]*"', ''))
end

--- Insert a newline before each block-level opening tag and after each
--- closing tag.  Idempotent on already-pretty input (extra newlines collapse).
local function break_blocks(s)
  for _, tag in ipairs(BLOCK_OPEN) do
    -- before opening tag
    s = s:gsub('(<' .. tag .. '[%s>/])', '\n%1')
    -- after the matching closing tag
    s = s:gsub('(</' .. tag .. '>)', '%1\n')
    -- after self-closing form
    s = s:gsub('(<' .. tag .. '[^>]*/>)', '%1\n')
  end
  return s
end

--- Indent lines by nesting depth based on a stack walk over open/close tags.
--- Tolerant of unmatched tags — falls back to the last known depth.
local function indent_lines(s, indent_unit)
  indent_unit = indent_unit or '  '
  local out = {}
  local depth = 0
  for line in (s .. '\n'):gmatch('([^\n]*)\n') do
    local trimmed = line:gsub('^%s+', ''):gsub('%s+$', '')
    if trimmed == '' then
      -- preserve a single blank line, no indent
      if out[#out] ~= '' then table.insert(out, '') end
    else
      -- A line that starts with </tag> dedents *before* printing.
      local pre_dedent = trimmed:match('^</')
      if pre_dedent and depth > 0 then depth = depth - 1 end

      table.insert(out, string.rep(indent_unit, depth) .. trimmed)

      -- Count tags opened vs closed on this line to update depth for next.
      -- Skip self-closing (<foo/>) and void/comment forms.
      local _, opens = trimmed:gsub('<[%w][^/>]-[^/]>', '')
      local _, closes = trimmed:gsub('</[%w]', '')
      -- Net change minus the dedent we already applied for the leading </>.
      local delta = opens - closes
      if pre_dedent then delta = delta + 1 end  -- we already consumed one close
      depth = math.max(0, depth + delta)
    end
  end
  -- drop trailing blank line if any
  while out[#out] == '' do table.remove(out) end
  return table.concat(out, '\n')
end

--- Pretty-print a Confluence storage-format string for human editing.
--- Returns a multi-line string with local-id attributes removed.
M.pretty = function(xhtml)
  if not xhtml or xhtml == '' then return '' end
  local s = strip_local_ids(xhtml)
  s = break_blocks(s)
  -- collapse runs of blank lines
  s = s:gsub('\n%s*\n%s*\n+', '\n\n')
  s = indent_lines(s, '  ')
  return s
end

--- Compact a (possibly pretty) storage string back to a single line for the
--- API.  Leaves text content untouched, just removes inter-tag whitespace.
M.compact = function(xhtml)
  if not xhtml or xhtml == '' then return '' end
  local s = xhtml
  -- Drop indentation/newlines that sit between tags only.
  s = s:gsub('>%s*\n%s*<', '><')
  -- Collapse remaining leading/trailing whitespace on each line, then join.
  local parts = {}
  for line in (s .. '\n'):gmatch('([^\n]*)\n') do
    local t = line:gsub('^%s+', ''):gsub('%s+$', '')
    if t ~= '' then table.insert(parts, t) end
  end
  return table.concat(parts, '')
end

return M
