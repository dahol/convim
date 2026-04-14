# convim — Neovim Confluence Editor

Edit Confluence pages directly in Neovim. Fetches page content from the
Confluence REST API v2, opens it in a scratch buffer, and writes it back on
save.

## Features

- Browse spaces and pages with `vim.ui.select`
- Edit page content in a dedicated `confluence` filetype buffer
- Save changes back to Confluence (correct version increment via PUT)
- Create new pages with `:ConfluenceNew`
- Search pages by title with `:ConfluenceSearch`
- Preview storage-format HTML as readable plain text
- Full pagination support — fetches all pages, not just the first 50
- Validates configuration before making any network request

## Requirements

- Neovim ≥ 0.9
- [plenary.nvim](https://github.com/nvim-lua/plenary.nvim)
- A Confluence Personal Access Token (Cloud or Data Center)

## Installation

### lazy.nvim

```lua
{
  "yourusername/convim.nvim",
  dependencies = { "nvim-lua/plenary.nvim" },
  config = function()
    require("convim").setup({
      base_url = os.getenv("CONFLUENCE_URL"),   -- e.g. https://your-org.atlassian.net
      token    = os.getenv("CONFLUENCE_TOKEN"),  -- Personal Access Token
    })
  end,
}
```

### packer.nvim

```lua
use {
  "yourusername/convim.nvim",
  requires = { "nvim-lua/plenary.nvim" },
}
```

## Configuration

```lua
require("convim").setup({
  base_url  = "https://your-org.atlassian.net",
  token     = "your_personal_access_token",
  space_key = "MYSPACE",  -- optional default space
})
```

Store credentials in environment variables rather than committing them.

## Commands

| Command | Description |
|---|---|
| `:ConfluenceListSpaces` | Browse and select a space |
| `:ConfluenceListPages` | List pages in the selected space |
| `:ConfluenceEdit [id]` | Open a page by ID, or pick from list |
| `:ConfluenceNew [title]` | Create a new page in the selected space |
| `:ConfluenceSearch [query]` | Search pages by title |
| `:ConfluenceSave` | Save the current buffer back to Confluence |
| `:ConfluencePreview` | Preview the current buffer as plain text |

## Key Mappings

Buffer-local mappings set automatically on `confluence` buffers:

| Key | Action |
|---|---|
| `<leader>cs` | `:ConfluenceSave` |
| `<leader>cp` | `:ConfluencePreview` |

## Testing

```bash
make test    # run all tests (requires nvim in PATH)
make lint    # lint with luacheck (luarocks install luacheck)
make fmt     # format with stylua  (cargo install stylua)
```

Tests run under Neovim's embedded LuaJIT with no external test framework
required. All HTTP calls are mocked so tests are fully offline.
# convim
