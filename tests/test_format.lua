-- tests/test_format.lua
-- Tests for lua/convim/format.lua

package.loaded['convim.format'] = nil
local format = require('convim.format')

-- ── strip local-id ────────────────────────────────────────────────────────────

local input = '<h1 local-id="10771f5b-1075-44e3-b407-91e995388579">Title</h1><p local-id="abc">Body</p>'
local pretty = format.pretty(input)
assert(not pretty:find('local%-id'),
  'pretty: strips all local-id attributes (got: ' .. pretty .. ')')
print('  format: pretty() strips local-id attributes')

-- ── breaks block elements onto their own lines ────────────────────────────────

local html = '<h1>Title</h1><p>Para 1</p><p>Para 2</p>'
local p = format.pretty(html)
local lines = vim.split(p, '\n', { plain = true })
-- should be at least 3 logical lines (h1, p, p)
assert(#lines >= 3,
  'pretty: breaks block elements (got ' .. #lines .. ' lines: ' .. p .. ')')
assert(p:find('<h1>Title</h1>'), 'pretty: preserves text content')
assert(p:find('Para 1'), 'pretty: preserves text content (1)')
assert(p:find('Para 2'), 'pretty: preserves text content (2)')
print('  format: pretty() breaks blocks onto their own lines')

-- ── nested elements get indented ──────────────────────────────────────────────

local nested = '<ul><li>One</li><li>Two</li></ul>'
local pn = format.pretty(nested)
-- li lines should be indented relative to ul
local li_lines = {}
for line in pn:gmatch('[^\n]+') do
  if line:find('<li>') then table.insert(li_lines, line) end
end
assert(#li_lines == 2, 'pretty: both <li> elements present')
assert(li_lines[1]:match('^%s+<li>'),
  'pretty: <li> is indented under <ul> (got: ' .. li_lines[1] .. ')')
print('  format: pretty() indents nested elements')

-- ── compact: roundtrip preserves text and tag structure ──────────────────────

local original = '<h1>Hello</h1><p>World</p><ul><li>A</li><li>B</li></ul>'
local round = format.compact(format.pretty(original))
-- After roundtrip we should have identical structure (local-ids weren't present here)
assert(round:find('<h1>Hello</h1>'), 'roundtrip: h1 preserved')
assert(round:find('<p>World</p>'),   'roundtrip: p preserved')
assert(round:find('<li>A</li>'),     'roundtrip: li preserved')
assert(round:find('<li>B</li>'),     'roundtrip: second li preserved')
assert(not round:find('\n'),         'compact: result is single-line')
print('  format: compact(pretty(x)) preserves structure and is single-line')

-- ── compact: empty / nil safe ─────────────────────────────────────────────────

assert(format.compact('') == '', 'compact: empty string → empty string')
assert(format.compact(nil) == '', 'compact: nil → empty string')
assert(format.pretty('') == '',   'pretty: empty string → empty string')
assert(format.pretty(nil) == '',  'pretty: nil → empty string')
print('  format: pretty/compact handle empty and nil input')

-- ── pretty preserves text inside tags exactly ────────────────────────────────

local with_text = '<p>Hello, world! Punctuation & such.</p>'
local pt = format.pretty(with_text)
assert(pt:find('Hello, world! Punctuation & such%.'),
  'pretty: leaves intra-tag text untouched')
print('  format: pretty() preserves text content verbatim')

-- ── compact removes pretty whitespace but not in-text spaces ─────────────────

local pretty_input = '<p>\n  Hello   world\n</p>'
local compact = format.compact(pretty_input)
-- Inter-tag whitespace gone, but in-text spacing preserved
assert(compact:find('Hello   world'),
  'compact: preserves multi-space in text content')
assert(not compact:find('\n'),
  'compact: removes all newlines')
print('  format: compact() removes structural whitespace, preserves in-text spacing')
