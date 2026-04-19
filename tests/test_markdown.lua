-- tests/test_markdown.lua
-- Tests for lua/convim/markdown.lua

package.loaded['convim.markdown'] = nil
local md = require('convim.markdown')

-- ── headings ─────────────────────────────────────────────────────────────────

local out, _ = md.from_storage('<h1>Hello</h1><h2>World</h2>')
assert(out:find('# Hello'),  'h1 → "# Hello"')
assert(out:find('## World'), 'h2 → "## World"')
print('  markdown: headings convert')

-- ── paragraphs and inline ───────────────────────────────────────────────────

out = md.from_storage('<p>Hi <strong>bold</strong> and <em>em</em> and <code>x</code>.</p>')
assert(out:find('%*%*bold%*%*'), 'strong → **bold**')
assert(out:find('%*em%*'),       'em → *em*')
assert(out:find('`x`'),          'code → `x`')
print('  markdown: inline strong/em/code')

-- ── links ────────────────────────────────────────────────────────────────────

out = md.from_storage('<p>see <a href="https://x.example">here</a>.</p>')
assert(out:find('%[here%]%(https://x%.example%)'), 'link → [text](url)')
print('  markdown: links')

-- ── lists (nested) ───────────────────────────────────────────────────────────

out = md.from_storage('<ul><li>A<ul><li>A1</li></ul></li><li>B</li></ul>')
assert(out:find('%- A'),    'ul item A')
assert(out:find('  %- A1'), 'nested ul item indented two spaces')
assert(out:find('%- B'),    'ul item B')
print('  markdown: nested unordered list')

out = md.from_storage('<ol><li>One</li><li>Two</li></ol>')
assert(out:find('1%. One'), 'ol item 1')
assert(out:find('2%. Two'), 'ol item 2')
print('  markdown: ordered list numbering')

-- ── code macro ───────────────────────────────────────────────────────────────

out = md.from_storage(
  '<ac:structured-macro ac:name="code">' ..
  '<ac:parameter ac:name="language">lua</ac:parameter>' ..
  '<ac:plain-text-body><![CDATA[print("hi")]]></ac:plain-text-body>' ..
  '</ac:structured-macro>')
assert(out:find('```lua'),       'code macro emits ```lua')
assert(out:find('print%("hi"%)'),'code body preserved')
assert(out:find('```\n*$') or out:find('```$'), 'code fence closes')
print('  markdown: code macro → fenced block')

-- ── unknown macro stashed ────────────────────────────────────────────────────

local raw = '<ac:structured-macro ac:name="info"><ac:rich-text-body><p>note</p></ac:rich-text-body></ac:structured-macro>'
local out2, meta = md.from_storage(raw)
assert(out2:find('<!%-%- convim:macro:1 %-%->'),
  'unknown macro replaced with placeholder (got: ' .. out2 .. ')')
assert(meta.macros[1] == raw, 'stashed verbatim')
print('  markdown: unknown macro stashed as placeholder')

-- ── round-trip preserves placeholder content ────────────────────────────────

local back = md.to_storage(out2, meta)
assert(back:find('ac:name="info"', 1, true),
  'round-trip restores info macro verbatim (got: ' .. back .. ')')
print('  markdown: round-trip restores stashed macros')

-- ── round-trip headings/paragraphs ──────────────────────────────────────────

local r = md.to_storage('# Title\n\nbody **strong** here', { macros = {} })
assert(r:find('<h1>Title</h1>', 1, true), 'h1 round-trip')
assert(r:find('<strong>strong</strong>', 1, true), 'bold round-trip')
print('  markdown: heading + paragraph round-trip')

-- ── round-trip code block ───────────────────────────────────────────────────

local code_md = '```lua\nprint("hi")\n```'
local r2 = md.to_storage(code_md, { macros = {} })
assert(r2:find('ac:name="code"', 1, true), 'code fence → code macro')
assert(r2:find('print%("hi"%)'), 'code body preserved through round-trip')
assert(r2:find('ac:name="language"', 1, true) and r2:find('>lua<'),
  'language parameter set')
print('  markdown: fenced code → code macro round-trip')

-- ── round-trip ul list ──────────────────────────────────────────────────────

local r3 = md.to_storage('- A\n- B', { macros = {} })
assert(r3:find('<ul>', 1, true) and r3:find('</ul>', 1, true), 'ul wrapper')
assert(r3:find('<li>A</li>', 1, true) and r3:find('<li>B</li>', 1, true),
  'list items')
print('  markdown: unordered list round-trip')

-- ── tables ──────────────────────────────────────────────────────────────────

local table_xhtml = '<table><tbody><tr><th>A</th><th>B</th></tr><tr><td>1</td><td>2</td></tr></tbody></table>'
local tmd = md.from_storage(table_xhtml)
assert(tmd:find('| A | B |'), 'table header row')
assert(tmd:find('| %-%-%- | %-%-%- |'), 'table separator')
assert(tmd:find('| 1 | 2 |'), 'table data row')

local rt = md.to_storage(tmd, { macros = {} })
assert(rt:find('<table>', 1, true) and rt:find('<th>A</th>', 1, true),
  'table round-trip preserves header cells')
assert(rt:find('<td>1</td>', 1, true), 'table round-trip preserves data')
print('  markdown: table round-trip')

-- ── empty / nil safe ────────────────────────────────────────────────────────

local e1, em = md.from_storage('')
assert(e1 == '' and em.original == '', 'empty storage')
assert(md.to_storage('', {}) == '', 'empty markdown')
assert(md.to_storage(nil, {}) == '', 'nil markdown')
print('  markdown: empty/nil safe')
