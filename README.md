# Neovim Confluence Editor

A Neovim plugin for editing Confluence pages with Markdown support.

## Features

- Connect to Confluence Cloud/Data Center
- List spaces and pages
- Edit pages using Markdown (auto-converts to HTML)
- Real-time preview
- Personal Access Token authentication

## Installation

### Using packer.nvim
```lua
use {
  "yourusername/convim.nvim",
  requires = {"nvim-lua/plenary.nvim"}
}
```

### Using lazy.nvim
```lua
{
  "yourusername/convim.nvim",
  dependencies = {"nvim-lua/plenary.nvim"},
  config = function()
    require("convim").setup({
      base_url = os.getenv("CONFLUENCE_URL"),
      token = os.getenv("CONFLUENCE_TOKEN")
    })
  end
}
```

## Configuration

```lua
require("convim`).setup({
  base_url = "https://your-domain.atlassian.net",
  token = "confluence_pat",
  space_key = "SPACE",
  markdown_converter = "rest/v2/render"
})
```

## Commands

- `ConfluenceLogin` - Authenticate with Confluence
- `ConfluenceListSpaces` - List available spaces
- `ConfluenceListPages` - List pages in current space
- `ConfluenceEdit <page_id>` - Edit a page
- `ConfluencePreview` - Preview as HTML
- `ConfluenceSave` - Save changes to Confluence

## Requirements

- Neovim 0.9+
- Lua 5.1+ with plenary.nvim
- Personal Access Token from Confluence
# convim
