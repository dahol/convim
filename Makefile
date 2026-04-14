# convim Makefile

.PHONY: test clean install fmt lint help

test:
	@nvim --headless -c "luafile luatest.lua" +qa!

clean:
	@rm -rf .luacov luacov.* 2>/dev/null || true

install:
	@mkdir -p ~/.local/share/nvim/site/pack/plugins/start/convim
	@cp -r lua plugin after ftplugin ~/.local/share/nvim/site/pack/plugins/start/convim/

fmt:
	@stylua lua/ tests/ plugin/ 2>/dev/null || echo "stylua not found (cargo install stylua)"

lint:
	@luacheck lua/ tests/ plugin/ 2>/dev/null || echo "luacheck not found (luarocks install luacheck)"

help:
	@echo "Targets:"
	@echo "  test     Run the test suite (requires nvim)"
	@echo "  clean    Remove build/coverage artefacts"
	@echo "  install  Copy plugin into Neovim's pack directory"
	@echo "  fmt      Format Lua with stylua"
	@echo "  lint     Lint Lua with luacheck"
