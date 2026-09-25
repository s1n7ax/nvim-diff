# Not NVIM: inside a :terminal that variable already holds a server socket path.
NVIM_BIN ?= nvim
LUA_DIRS := lua plugin

.PHONY: check lint fmt fmt-check health clean

## check: everything CI would run
check: fmt-check lint

## lint: luacheck
lint:
	luacheck $(LUA_DIRS)

## fmt: format in place
fmt:
	stylua $(LUA_DIRS)

## fmt-check: fail when anything is unformatted
fmt-check:
	stylua --check $(LUA_DIRS)

## health: :checkhealth nvim-diff in a Neovim with nothing else loaded
health:
	$(NVIM_BIN) --clean --cmd 'set rtp^=.' -c 'lua require("nvim-diff").setup()' -c 'checkhealth nvim-diff'

clean:
	rm -f luacheck-cache
