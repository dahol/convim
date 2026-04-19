" Vim syntax file for Confluence storage format (XHTML + ac:/ri: macros).
"
" Builds on top of the builtin html syntax and adds:
"   * distinct highlight for ac:/ri: namespaced tags and attributes
"   * conceals noisy attributes the user shouldn't have to look at
"     (ac:schema-version, ac:macro-id, ac:local-id, data-layout)
"   * conceals <![CDATA[ ... ]]> wrappers, leaving just the content visible
"   * folding for <ac:structured-macro> blocks
"
" Toggle conceal: `:set conceallevel=0` to see everything raw, or `:set
" conceallevel=2` (the default we set in ftplugin) to hide noise.

if exists('b:current_syntax')
  finish
endif

" Start from html so we get all the standard tag/attr/entity highlighting.
runtime! syntax/html.vim
unlet! b:current_syntax

" ── ac: / ri: namespaced macros ──────────────────────────────────────────────
" e.g. <ac:structured-macro ...>  </ac:rich-text-body>  <ri:user .../>
syntax match confluenceMacroTag       /<\/\?\(ac\|ri\):[a-zA-Z0-9_-]\+/  contains=NONE
syntax match confluenceMacroSelfClose /\/>/

" The macro name itself (highlighted brighter than surrounding html tags)
highlight default link confluenceMacroTag       Special
highlight default link confluenceMacroSelfClose Special

" Attribute names within ac:/ri: tags
syntax match confluenceMacroAttr      / \(ac\|ri\):[a-zA-Z0-9_-]\+=/
highlight default link confluenceMacroAttr Identifier

" ── concealed noise ─────────────────────────────────────────────────────────
" These attributes are bookkeeping the editor never needs to see.
" `conceal` makes them disappear when conceallevel >= 2, but they're still in
" the buffer and saved unmodified.

syntax match confluenceConcealAttr / \(ac:schema-version\|ac:macro-id\|ac:local-id\|data-layout\)="[^"]*"/ conceal

" CDATA wrappers — the content matters, the wrapper doesn't.
" Conceal just `<![CDATA[` and `]]>`; leave inner text alone.
syntax match confluenceCDataOpen  /<!\[CDATA\[/ conceal
syntax match confluenceCDataClose /\]\]>/        conceal

" ── folding for structured-macro blocks ─────────────────────────────────────
" Each <ac:structured-macro ...> ... </ac:structured-macro> becomes one fold.
syntax region confluenceMacroBlock
  \ start=/<ac:structured-macro\>/
  \ end=/<\/ac:structured-macro>/
  \ transparent
  \ fold
  \ keepend

" plain-text-body is large and noisy; fold it on its own too.
syntax region confluencePlainBody
  \ start=/<ac:plain-text-body>/
  \ end=/<\/ac:plain-text-body>/
  \ transparent
  \ fold
  \ keepend

let b:current_syntax = 'confluence'
