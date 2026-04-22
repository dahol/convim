# convim — Neovim AiSlop Confluence Editor

Edit Confluence pages directly in Neovim. Fetches page content from the
Confluence REST API v2, opens it in a scratch buffer, and writes it back on
save.

## Features

- Browse spaces and pages with `vim.ui.select` (or telescope if installed)
- Edit page content as **markdown** with lossless round-trip back to Confluence storage XHTML on save
- Unmodelled macros (info panels, layouts, etc.) are stashed verbatim and re-inlined on save — they survive editing intact
- `:ConfluenceEditRaw` escape hatch for editing the storage XHTML directly
- Save changes back to Confluence with plain `:w` (correct version increment via PUT)
- Create new pages with `:ConfluenceNew` (resolves space key → ID for v2)
- Search pages by title with `:ConfluenceSearch`
- Convert wiki markup to storage format and preview as readable plain text
- Full pagination support — fetches all spaces/pages, not just the first 50
- Validates configuration before making any network request
- `:checkhealth convim` reports config, dependencies, and live auth status

## Requirements

- Neovim ≥ 0.9
- [plenary.nvim](https://github.com/nvim-lua/plenary.nvim) (for `plenary.curl`)
- [telescope.nvim](https://github.com/nvim-telescope/telescope.nvim) *(optional;
  enables a floating live-search picker for `:ConfluenceSearch` and
  `:ConfluenceListPages`. Falls back to `vim.ui.select` if not installed.)*
- `curl` in `$PATH`
- Confluence credentials:
  - **Cloud**: an account email + API token (`auth = "basic"`, auto-detected
    for `*.atlassian.net` hosts)
  - **Data Center / Server**: a Personal Access Token (`auth = "bearer"`)

## Installation

### lazy.nvim

```lua
{
  "dahol/convim",
  dependencies = { "nvim-lua/plenary.nvim" },
  config = function()
    require("convim").setup({
      base_url = os.getenv("CONFLUENCE_URL"),    -- e.g. https://your-org.atlassian.net
      email    = os.getenv("CONFLUENCE_EMAIL"),  -- only for Cloud
      token    = os.getenv("CONFLUENCE_TOKEN"),  -- API token (Cloud) or PAT (DC)
    })
  end,
}
```

### packer.nvim

```lua
use {
  "dahol/convim",
  requires = { "nvim-lua/plenary.nvim" },
}
```

## Configuration

```lua
require("convim").setup({
  base_url  = "https://your-org.atlassian.net",
  email     = "you@example.com",        -- required for Cloud (auth="basic")
  token     = "your_api_token_or_pat",
  auth      = "basic",                  -- "basic" | "bearer"; auto-detected if omitted
  space_key = "MYSPACE",                -- optional default space
})
```

Auth scheme is auto-detected from `base_url`: hosts on `atlassian.net` use
HTTP Basic (Cloud), everything else uses Bearer (Data Center PAT). Override
with `auth = "basic"` or `auth = "bearer"`.

Store credentials in environment variables rather than committing them.

## Commands

| Command | Description |
|---|---|
| `:ConfluenceVerifyAuth` | Probe the API and report auth status |
| `:ConfluenceListSpaces` | Browse and select a space |
| `:ConfluenceListPages` | List pages in the selected space |
| `:ConfluenceEdit [id]` | Open a page by ID, or pick from list (markdown view) |
| `:ConfluenceEditRaw <id>` | Open a page as raw storage XHTML (no markdown round-trip) |
| `:ConfluenceNew [title]` | Create a new page in the selected space |
| `:ConfluenceSearch [query]` | Search pages by title |
| `:ConfluenceSave` | Save the current buffer back to Confluence (or just `:w`) |
| `:ConfluencePreview` | Convert the current buffer (wiki → storage) and preview |

Run `:checkhealth convim` to verify your install and credentials.

## Key Mappings

Buffer-local mappings set automatically on `confluence` buffers:

| Key | Action |
|---|---|
| `<leader>cs` | `:ConfluenceSave` |
| `<leader>cp` | `:ConfluencePreview` |

## Buffer format

`:ConfluenceEdit` converts the page's storage XHTML to **markdown** for
editing — headings, lists, links, **bold**/*italic*/`code`, fenced code blocks,
tables, and blockquotes all round-trip back to storage XHTML on save.

Constructs convim doesn't natively model (info panels, layouts, status
macros, task lists, anything else under `<ac:structured-macro>`) are replaced
in the buffer with placeholder lines like `<!-- convim:macro:1 -->` and the
verbatim XHTML is stashed in a buffer-local variable. On save, placeholders
are re-inlined unchanged, so opening and saving a page round-trips losslessly
even when convim doesn't understand every block.

If a page renders poorly as markdown, `:ConfluenceEditRaw <id>` opens it in
the original storage-XHTML view — what you save is exactly what you see.

## Testing

```bash
make test    # run all tests (requires nvim in PATH)
make lint    # lint with luacheck (luarocks install luacheck)
make fmt     # format with stylua  (cargo install stylua)
```

Tests run under Neovim's embedded LuaJIT with no external test framework
required. All HTTP calls are mocked so tests are fully offline.
