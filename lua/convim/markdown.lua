-- Lossless(-ish) Markdown <-> Confluence storage XHTML conversion.
--
-- The point of this module is to give the user a *readable, markdown-flavoured*
-- editing experience while preserving the original storage XHTML well enough
-- to round-trip on save without destroying macros, layouts, or other
-- Confluence-specific constructs we don't natively understand.
--
-- Strategy
-- --------
-- 1. `from_storage(xhtml)` walks the storage XHTML and converts the well-known
--    block/inline subset (headings, paragraphs, bold/italic/code, links,
--    lists, code macros, tables, hr, blockquote, br) into markdown.
-- 2. Anything we don't have a markdown rendering for — most importantly any
--    `<ac:structured-macro>` other than `code` — is replaced with a placeholder
--    line of the form `<!-- convim:macro:N -->` and the original XHTML chunk is
--    stashed in a `meta.macros[N]` slot.
-- 3. `to_storage(md, meta)` converts the markdown back to storage XHTML and
--    re-inlines the placeholders verbatim.
-- 4. `meta.original` keeps the full original storage so the save path can fall
--    back to it if conversion produced nothing meaningful (e.g. user opened a
--    page and made no edits).
--
-- Non-goals
-- ---------
-- This is *not* a CommonMark parser nor a full XHTML parser.  It is a
-- pragmatic, regex-driven converter for the shapes Confluence actually emits.
-- For pages outside that shape we still survive — they just show up as
-- macro placeholders in the buffer, which the user can leave alone.

local M = {}

-- ────────────────────────────────────────────────────────────────────────────
-- Shared helpers
-- ────────────────────────────────────────────────────────────────────────────

local function trim(s) return ((s or ''):gsub('^%s+', ''):gsub('%s+$', '')) end

--- Decode the small set of XML entities Confluence actually uses in text
--- nodes.  We only undo what we re-encode, to keep the round-trip stable.
local function decode_entities(s)
  if not s then return '' end
  return (s
    :gsub('&lt;',   '<')
    :gsub('&gt;',   '>')
    :gsub('&quot;', '"')
    :gsub('&#39;',  "'")
    :gsub('&apos;', "'")
    :gsub('&nbsp;', ' ')
    :gsub('&amp;',  '&'))   -- last, to avoid double-decoding
end

--- Encode the same set when emitting back into XHTML.
local function encode_entities(s)
  if not s then return '' end
  return (s
    :gsub('&', '&amp;')
    :gsub('<', '&lt;')
    :gsub('>', '&gt;'))
end

--- Strip every tag from a chunk and decode entities — used as the fallback
--- text rendering for nodes whose structure we don't model.
local function tags_to_text(s)
  if not s or s == '' then return '' end
  s = s:gsub('<[^>]+>', '')
  return decode_entities(s)
end

-- ────────────────────────────────────────────────────────────────────────────
-- Inline conversion: storage XHTML → markdown
-- ────────────────────────────────────────────────────────────────────────────

--- Convert the inline contents of a block (text + simple inline tags) to
--- markdown.  Operates only on inline-level constructs; block tags inside
--- this string are left as-is (the caller is responsible for splitting blocks
--- before calling).
local function inline_to_md(s, meta)
  if not s then return '' end
  -- <br/> → newline (markdown hard break is two trailing spaces, but inside a
  -- paragraph an actual newline reads better in nvim).
  s = s:gsub('<br%s*/?>', '  \n')

  -- Stash inline macros before they get destroyed.
  if meta then
    s = s:gsub('<ac:structured%-macro(.-)</ac:structured%-macro>', function(inner)
      meta.macros = meta.macros or {}
      local raw = '<ac:structured-macro' .. inner .. '</ac:structured-macro>'
      table.insert(meta.macros, raw)
      return string.format('<!-- convim:macro:%d -->', #meta.macros)
    end)
    s = s:gsub('<ac:image(.-)</ac:image>', function(inner)
      meta.macros = meta.macros or {}
      local raw = '<ac:image' .. inner .. '</ac:image>'
      table.insert(meta.macros, raw)
      return string.format('<!-- convim:macro:%d -->', #meta.macros)
    end)
    s = s:gsub('<ac:emoticon[^>]*/>', function(raw)
      meta.macros = meta.macros or {}
      table.insert(meta.macros, raw)
      local emoji = raw:match('ac:emoji%-shortname="([^"]+)"')
      if emoji then return string.format('<!-- convim:macro:%d -->%s', #meta.macros, emoji) end
      return string.format('<!-- convim:macro:%d -->', #meta.macros)
    end)
  end

  -- <strong>/<b>
  s = s:gsub('<strong[^>]*>(.-)</strong>', '**%1**')
  s = s:gsub('<b>(.-)</b>',                 '**%1**')

  -- <em>/<i>
  s = s:gsub('<em[^>]*>(.-)</em>', '*%1*')
  s = s:gsub('<i>(.-)</i>',         '*%1*')

  -- <code>
  s = s:gsub('<code[^>]*>(.-)</code>', '`%1`')

  -- <a href="…">text</a>
  s = s:gsub('<a%s+[^>]-href="([^"]*)"[^>]*>(.-)</a>', '[%2](%1)')

  -- <ac:link><ri:page ri:content-title="title" /><ac:link-body>text</ac:link-body></ac:link>
  s = s:gsub('<ac:link[^>]*>.-<ri:page ri:content%-title="([^"]+)"[^>]*/><ac:link%-body>(.-)</ac:link%-body>.-</ac:link>', '[%2](ac:page:%1)')
  -- Without link body
  s = s:gsub('<ac:link[^>]*>.-<ri:page ri:content%-title="([^"]+)"[^>]*/>.-</ac:link>', '[%1](ac:page:%1)')

  -- <ac:link><ri:user ri:account-id="id" /></ac:link>
  s = s:gsub('<ac:link[^>]*>.-<ri:user ri:account%-id="([^"]+)"[^>]*/>.-</ac:link>', '[@user](ac:user:%1)')

  -- <time datetime="YYYY-MM-DD" />
  s = s:gsub('<time datetime="([^"]+)"%s*/>', '<time:%1>')

  -- Strip any remaining inline tags we don't model rather than leaking them.
  s = s:gsub('<span[^>]*>', ''):gsub('</span>', '')

  return decode_entities(s)
end

-- ────────────────────────────────────────────────────────────────────────────
-- Block extraction
-- ────────────────────────────────────────────────────────────────────────────

--- Slice the storage string into top-level blocks.  Recognises block elements
--- by their opening tag and pairs them with their matching close.  Anything
--- not inside a known block is emitted as a 'text' fragment (whitespace
--- between blocks, basically).
---
--- Returns { { kind = 'tag'|'text', tag = '…', open = '<…>', inner = '…',
---             raw = '<…>…</…>' }, … }
local BLOCK_TAGS = {
  ['p'] = true, ['ul'] = true, ['ol'] = true, ['table'] = true,
  ['blockquote'] = true, ['pre'] = true, ['hr'] = true,
  ['h1'] = true, ['h2'] = true, ['h3'] = true,
  ['h4'] = true, ['h5'] = true, ['h6'] = true,
  ['ac:structured-macro'] = true,
  ['ac:layout'] = true,
  ['ac:layout-section'] = true,
  ['ac:task-list'] = true,
}

local function tokenise(s)
  local out = {}
  local i = 1
  local len = #s

  while i <= len do
    -- Find the next `<` that starts a candidate tag.
    local lt = s:find('<', i, true)
    if not lt then
      local rest = s:sub(i)
      if trim(rest) ~= '' then table.insert(out, { kind = 'text', raw = rest }) end
      break
    end

    -- Extract the tag name (letters, digits, ':', '-').
    local name = s:match('^<([%w:%-]+)', lt)
    if not name or not BLOCK_TAGS[name] then
      -- Not a block tag we care about; skip past this `<` so we keep scanning.
      -- Inter-block text accumulates with the next emitted text fragment.
      i = lt + 1
    else
      -- Emit any inter-block text before this match.
      if lt > i then
        local pre = s:sub(i, lt - 1)
        if trim(pre) ~= '' then table.insert(out, { kind = 'text', raw = pre }) end
      end

      -- Find end of opening tag.
      local open_end = s:find('>', lt, true)
      if not open_end then break end
      local open = s:sub(lt, open_end)
      local self_closing = open:sub(-2, -2) == '/'

      if self_closing or name == 'hr' then
        table.insert(out, {
          kind = 'tag', tag = name, open = open,
          inner = '', raw = open,
        })
        i = open_end + 1
      else
        -- Find matching closing tag, accounting for nested same-named opens.
        local esc = name:gsub('[%-%:]', '%%%0')
        local close_pat  = '</' .. esc .. '%s*>'
        local open_again = '<'  .. esc .. '[%s/>]'
        local depth = 1
        local cursor = open_end + 1
        local close_from, close_to
        while depth > 0 do
          local nfrom, nto = s:find(open_again, cursor)
          local cfrom, cto = s:find(close_pat,  cursor)
          if not cfrom then break end
          if nfrom and nfrom < cfrom then
            depth = depth + 1
            cursor = nto + 1
          else
            depth = depth - 1
            if depth == 0 then close_from, close_to = cfrom, cto end
            cursor = cto + 1
          end
        end

        if not close_from then
          table.insert(out, { kind = 'text', raw = s:sub(lt) })
          break
        end

        local inner = s:sub(open_end + 1, close_from - 1)
        table.insert(out, {
          kind  = 'tag',
          tag   = name,
          open  = open,
          inner = inner,
          raw   = s:sub(lt, close_to),
        })
        i = close_to + 1
      end
    end
  end

  return out
end

-- ────────────────────────────────────────────────────────────────────────────
-- List rendering
-- ────────────────────────────────────────────────────────────────────────────

--- Extract balanced <li>…</li> chunks from a <ul>/<ol> inner string,
--- accounting for nested <li> in sub-lists.
local function split_lis(inner)
  local items = {}
  local i = 1
  local len = #inner
  while i <= len do
    local s = inner:find('<li', i)
    if not s then break end
    local open_end = inner:find('>', s, true)
    if not open_end then break end
    local depth = 1
    local cursor = open_end + 1
    local close_from, close_to
    while depth > 0 do
      local nfrom, nto = inner:find('<li[%s>]', cursor)
      local cfrom, cto = inner:find('</li%s*>', cursor)
      if not cfrom then break end
      if nfrom and nfrom < cfrom then
        depth = depth + 1
        cursor = nto + 1
      else
        depth = depth - 1
        if depth == 0 then close_from, close_to = cfrom, cto end
        cursor = cto + 1
      end
    end
    if not close_from then break end
    table.insert(items, inner:sub(open_end + 1, close_from - 1))
    i = close_to + 1
  end
  return items
end

--- Render the inner contents of a <ul> or <ol> as a markdown list.
--- `ordered` is a boolean.  `depth` is the current indent depth (0-based).
local function list_to_md(inner, ordered, depth, meta)
  depth = depth or 0
  local indent = string.rep('  ', depth)
  local lines = {}
  local idx = 0

  for _, li in ipairs(split_lis(inner)) do
    idx = idx + 1
    local marker = ordered and (idx .. '. ') or '- '

    -- Separate nested lists from the leading text.
    local lead = li
    local nested_md = {}

    -- Pull out nested ul/ol blocks (in order) and recurse.
    lead = lead:gsub('<ul[^>]*>(.-)</ul>', function(body)
      table.insert(nested_md, list_to_md(body, false, depth + 1, meta))
      return ''
    end)
    lead = lead:gsub('<ol[^>]*>(.-)</ol>', function(body)
      table.insert(nested_md, list_to_md(body, true, depth + 1, meta))
      return ''
    end)

    -- The lead text may still contain a wrapping <p>; unwrap once.
    lead = lead:gsub('^%s*<p[^>]*>(.-)</p>%s*$', '%1')

    local text = trim(inline_to_md(lead, meta))
    table.insert(lines, indent .. marker .. text)
    for _, nl in ipairs(nested_md) do
      table.insert(lines, nl)
    end
  end

  return table.concat(lines, '\n')
end

-- ────────────────────────────────────────────────────────────────────────────
-- Macro handling
-- ────────────────────────────────────────────────────────────────────────────

--- Stash the verbatim XHTML chunk in `meta.macros` and return the placeholder
--- line that takes its place in the markdown buffer.
local function stash_macro(raw, meta)
  meta.macros = meta.macros or {}
  table.insert(meta.macros, raw)
  return string.format('<!-- convim:macro:%d -->', #meta.macros)
end

--- Try to extract the body of a `code` structured-macro and render it as a
--- fenced markdown code block.  Returns nil if this isn't a code macro.
local function code_macro_to_md(open, inner)
  if not open:find('ac:name="code"', 1, true) then return nil end

  local lang = inner:match(
    '<ac:parameter%s+ac:name="language"[^>]*>([^<]*)</ac:parameter>')
  local body = inner:match(
    '<ac:plain%-text%-body>%s*<!%[CDATA%[(.-)%]%]>%s*</ac:plain%-text%-body>')
    or inner:match('<ac:plain%-text%-body[^>]*>(.-)</ac:plain%-text%-body>')

  if not body then return nil end

  body = decode_entities(body)
  -- Trim a single leading/trailing newline added by Confluence.
  body = body:gsub('^\n', ''):gsub('\n$', '')

  return string.format('```%s\n%s\n```', lang or '', body)
end

-- ────────────────────────────────────────────────────────────────────────────
-- Table rendering (best-effort: simple rectangular tables only)
-- ────────────────────────────────────────────────────────────────────────────

local function table_to_md(inner, meta)
  local rows = {}
  for tr in inner:gmatch('<tr[^>]*>(.-)</tr>') do
    local cells = {}
    local is_header = tr:find('<th', 1, true) ~= nil
    for cell in tr:gmatch('<t[hd][^>]*>(.-)</t[hd]>') do
      local txt = trim(inline_to_md(cell:gsub('<p[^>]*>', ''):gsub('</p>', ' '), meta))
      txt = txt:gsub('|', '\\|'):gsub('\n', ' ')
      table.insert(cells, txt)
    end
    table.insert(rows, { cells = cells, header = is_header })
  end

  if #rows == 0 then return '' end

  -- If no row was marked as header, treat the first as one (markdown requires
  -- a header row).
  if not rows[1].header then rows[1].header = true end

  local n_cols = 0
  for _, r in ipairs(rows) do
    if #r.cells > n_cols then n_cols = #r.cells end
  end

  local function row_line(cells)
    local padded = {}
    for c = 1, n_cols do padded[c] = cells[c] or '' end
    return '| ' .. table.concat(padded, ' | ') .. ' |'
  end

  local sep = {}
  for _ = 1, n_cols do table.insert(sep, '---') end
  local sep_line = '| ' .. table.concat(sep, ' | ') .. ' |'

  local out = { row_line(rows[1].cells), sep_line }
  for i = 2, #rows do table.insert(out, row_line(rows[i].cells)) end
  return table.concat(out, '\n')
end

-- ────────────────────────────────────────────────────────────────────────────
-- Public: storage → markdown
-- ────────────────────────────────────────────────────────────────────────────

--- Convert a Confluence storage XHTML string to markdown.
--- Returns `md, meta` where:
---   md   = a markdown string suitable for editing in a `markdown` buffer
---   meta = { original = <input>, macros = { [N] = "<…verbatim XHTML…>", … } }
M.from_storage = function(xhtml)
  local meta = { original = xhtml or '', macros = {} }
  if not xhtml or xhtml == '' then return '', meta end

  local tokens = tokenise(xhtml)
  local out = {}

  for _, tok in ipairs(tokens) do
    if tok.kind == 'text' then
      local t = trim(inline_to_md(tok.raw, meta))
      if t ~= '' then table.insert(out, t) end
    elseif tok.tag:match('^h[1-6]$') then
      local level = tonumber(tok.tag:sub(2))
      local text = trim(inline_to_md(tok.inner, meta))
      table.insert(out, string.rep('#', level) .. ' ' .. text)
    elseif tok.tag == 'p' then
      local text = trim(inline_to_md(tok.inner, meta))
      if text ~= '' then table.insert(out, text) end
    elseif tok.tag == 'hr' then
      table.insert(out, '---')
    elseif tok.tag == 'blockquote' then
      local text = trim(inline_to_md(tok.inner:gsub('<p[^>]*>', ''):gsub('</p>', '\n'), meta))
      local quoted = {}
      for line in (text .. '\n'):gmatch('([^\n]*)\n') do
        table.insert(quoted, '> ' .. line)
      end
      while quoted[#quoted] == '> ' do table.remove(quoted) end
      table.insert(out, table.concat(quoted, '\n'))
    elseif tok.tag == 'ul' or tok.tag == 'ol' then
      table.insert(out, list_to_md(tok.inner, tok.tag == 'ol', 0, meta))
    elseif tok.tag == 'pre' then
      table.insert(out, '```\n' .. tags_to_text(tok.inner) .. '\n```')
    elseif tok.tag == 'table' then
      table.insert(out, table_to_md(tok.inner, meta))
    elseif tok.tag == 'ac:structured-macro' then
      local code = code_macro_to_md(tok.open, tok.inner)
      if code then
        table.insert(out, code)
      else
        table.insert(out, stash_macro(tok.raw, meta))
      end
    else
      -- Layouts, task lists, anything else we don't model: keep verbatim.
      table.insert(out, stash_macro(tok.raw, meta))
    end
  end

  return table.concat(out, '\n\n'), meta
end

-- ── inline markdown → XHTML ─────────────────────────────────────────────────

M._inline_to_xhtml = function(s)
  if not s or s == '' then return '' end

  -- Encode entities first so the markup we *insert* below survives.
  -- We must do this before introducing literal `<` / `>` in tags.
  s = encode_entities(s)

  -- Inline code `xxx`  (escape any markdown markers inside back to text)
  s = s:gsub('`([^`]+)`', function(code)
    return '<code>' .. code .. '</code>'
  end)

  -- Links [text](url), including ac:page: and ac:user: pseudo-urls
  s = s:gsub('%[([^%]]+)%]%(([^)]+)%)', function(text, url)
    if url:match('^ac:page:(.*)$') then
      local page = url:match('^ac:page:(.*)$')
      if text == page then
        return string.format('<ac:link><ri:page ri:content-title="%s" /></ac:link>', page)
      else
        return string.format('<ac:link><ri:page ri:content-title="%s" /><ac:link-body>%s</ac:link-body></ac:link>', page, text)
      end
    elseif url:match('^ac:user:(.*)$') then
      local account_id = url:match('^ac:user:(.*)$')
      return string.format('<ac:link><ri:user ri:account-id="%s" /></ac:link>', account_id)
    else
      return string.format('<a href="%s">%s</a>', url, text)
    end
  end)

  -- Bold **x**
  s = s:gsub('%*%*([^%*]+)%*%*', '<strong>%1</strong>')
  -- Italic *x*  (single-star, not part of **)
  s = s:gsub('%*([^%*\n]+)%*', '<em>%1</em>')

  -- <time:YYYY-MM-DD>
  s = s:gsub('<time:([^>]+)>', '<time datetime="%1" />')

  return s
end

-- ────────────────────────────────────────────────────────────────────────────
-- Public: markdown → storage
-- ────────────────────────────────────────────────────────────────────────────

--- Convert markdown back to storage XHTML.  `meta` is the table returned by
--- `from_storage`; placeholders are re-inlined from `meta.macros`.
--- Conversion intentionally mirrors the subset that `from_storage` emits.
M.to_storage = function(md, meta)
  meta = meta or {}
  if not md or md == '' then return '' end

  -- Split into blocks separated by blank line(s).  We preserve blocks that are
  -- code fences / tables / lists as units even if they contain blank lines.
  local raw_lines = vim.split(md, '\n', { plain = true })

  local blocks = {}
  local cur = {}
  local in_fence = false

  local function flush()
    if #cur > 0 then
      table.insert(blocks, table.concat(cur, '\n'))
      cur = {}
    end
  end

  for _, line in ipairs(raw_lines) do
    if line:match('^```') then
      table.insert(cur, line)
      if in_fence then
        in_fence = false
        flush()
      else
        in_fence = true
      end
    elseif in_fence then
      table.insert(cur, line)
    elseif line:match('^%s*$') then
      flush()
    else
      table.insert(cur, line)
    end
  end
  flush()

  local out = {}

  for _, block in ipairs(blocks) do
    local first = block:match('^[^\n]*') or ''

    -- Macro placeholder
    local idx = first:match('^<!%-%-%s*convim:macro:(%d+)%s*%-%->%s*$')
    if idx and meta.macros and meta.macros[tonumber(idx)] then
      table.insert(out, meta.macros[tonumber(idx)])

    -- Fenced code block → ac:structured-macro ac:name="code"
    elseif first:match('^```') then
      local lang = first:match('^```(.*)$') or ''
      local body_lines = vim.split(block, '\n', { plain = true })
      table.remove(body_lines, 1)            -- strip opening fence
      if body_lines[#body_lines]
         and body_lines[#body_lines]:match('^```') then
        table.remove(body_lines)             -- strip closing fence
      end
      local body = table.concat(body_lines, '\n')
      local lang_param = ''
      if lang and lang ~= '' then
        lang_param = string.format(
          '<ac:parameter ac:name="language">%s</ac:parameter>', lang)
      end
      table.insert(out, string.format(
        '<ac:structured-macro ac:name="code">%s' ..
        '<ac:plain-text-body><![CDATA[%s]]></ac:plain-text-body>' ..
        '</ac:structured-macro>',
        lang_param, body))

    -- ATX heading
    elseif first:match('^#') then
      local hashes, text = first:match('^(#+)%s+(.*)$')
      local level = math.min(#hashes, 6)
      table.insert(out, string.format('<h%d>%s</h%d>',
        level, M._inline_to_xhtml(text), level))

    -- Horizontal rule
    elseif first:match('^%-%-%-+%s*$') and not block:find('\n') then
      table.insert(out, '<hr/>')

    -- Blockquote
    elseif first:match('^>') then
      local text_lines = {}
      for line in (block .. '\n'):gmatch('([^\n]*)\n') do
        table.insert(text_lines, (line:gsub('^>%s?', '')))
      end
      table.insert(out, '<blockquote><p>' ..
        M._inline_to_xhtml(table.concat(text_lines, '<br/>')) ..
        '</p></blockquote>')

    -- Unordered list
    elseif first:match('^%s*[-*+]%s+') then
      table.insert(out, M._md_list_to_xhtml(block, false))

    -- Ordered list
    elseif first:match('^%s*%d+%.%s+') then
      table.insert(out, M._md_list_to_xhtml(block, true))

    -- Table
    elseif block:find('\n|') and first:match('^|') then
      table.insert(out, M._md_table_to_xhtml(block))

    else
      -- Default: paragraph.  Internal newlines become <br/>.
      local text = block:gsub('\n', '<br/>')
      table.insert(out, '<p>' .. M._inline_to_xhtml(text) .. '</p>')
    end
  end

  local final_out = table.concat(out, '')

  -- Re-inline any macros that were embedded within text blocks and got escaped
  if meta and meta.macros then
    final_out = final_out:gsub('&lt;!%-%-%s*convim:macro:(%d+)%s*%-%-&gt;', function(idx)
      return meta.macros[tonumber(idx)] or ''
    end)
    -- Also handle them if they weren't escaped (e.g. from the block-level loop)
    -- Actually, block-level loop inserts the macro raw without escaping.
  end

  return final_out
end

-- ── markdown lists → XHTML ─────────────────────────────────────────────────

--- Parse a list block (possibly nested via 2-space indent) into XHTML
--- <ul>/<ol> with <li>s.  Items at deeper indent become nested lists inside
--- the most recent <li>.
M._md_list_to_xhtml = function(block, ordered)
  local lines = vim.split(block, '\n', { plain = true })

  -- Each item: { depth, ordered, text, children = { …items… } }
  local function parse(start, base_indent)
    local items = {}
    local i = start
    while i <= #lines do
      local line = lines[i]
      local indent, marker, text =
        line:match('^(%s*)([-*+])%s+(.*)$')
      local is_ordered = false
      if not indent then
        indent, _, text = line:match('^(%s*)(%d+%.)%s+(.*)$')
        is_ordered = true
      end
      if not indent then break end
      local d = #indent
      if d < base_indent then break end
      if d > base_indent then
        -- Should have been consumed as a child of the previous item.
        break
      end
      local item = { depth = d, ordered = is_ordered, text = text, children = {} }
      i = i + 1
      -- Gather children with deeper indent.
      while i <= #lines do
        local nindent = lines[i]:match('^(%s*)[-*+%d]')
        if not nindent or #nindent <= d then break end
        local children, ni = parse(i, #nindent)
        for _, c in ipairs(children) do table.insert(item.children, c) end
        i = ni
      end
      table.insert(items, item)
    end
    return items, i
  end

  local items = parse(1, 0)

  local function render(list_items, parent_ordered)
    local tag = parent_ordered and 'ol' or 'ul'
    local parts = { '<' .. tag .. '>' }
    for _, it in ipairs(list_items) do
      local li = '<li>' .. M._inline_to_xhtml(it.text)
      if #it.children > 0 then
        -- Group consecutive children of the same kind into one nested list.
        local groups, cur_kind = {}, nil
        for _, c in ipairs(it.children) do
          if c.ordered ~= cur_kind then
            table.insert(groups, { ordered = c.ordered, items = {} })
            cur_kind = c.ordered
          end
          table.insert(groups[#groups].items, c)
        end
        for _, g in ipairs(groups) do
          li = li .. render(g.items, g.ordered)
        end
      end
      li = li .. '</li>'
      table.insert(parts, li)
    end
    table.insert(parts, '</' .. tag .. '>')
    return table.concat(parts)
  end

  return render(items, ordered)
end

-- ── markdown tables → XHTML ─────────────────────────────────────────────────

M._md_table_to_xhtml = function(block)
  local lines = vim.split(block, '\n', { plain = true })
  -- Drop separator row (the |---|---| line).
  local body = {}
  for i, line in ipairs(lines) do
    if i ~= 2 then table.insert(body, line) end
  end

  local function split_row(line)
    local cells = {}
    -- strip leading/trailing pipe
    line = line:gsub('^%s*|', ''):gsub('|%s*$', '')
    for cell in (line .. '|'):gmatch('([^|]*)|') do
      table.insert(cells, trim(cell))
    end
    return cells
  end

  local out = { '<table><tbody>' }
  for i, line in ipairs(body) do
    local cells = split_row(line)
    local row = { '<tr>' }
    local tag = (i == 1) and 'th' or 'td'
    for _, c in ipairs(cells) do
      table.insert(row, string.format('<%s>%s</%s>', tag,
        M._inline_to_xhtml(c), tag))
    end
    table.insert(row, '</tr>')
    table.insert(out, table.concat(row))
  end
  table.insert(out, '</tbody></table>')
  return table.concat(out)
end

return M
