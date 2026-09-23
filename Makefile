# Not NVIM: inside a :terminal that variable already holds a server socket path.
NVIM_BIN ?= nvim
LUA_DIRS := lua plugin tests

# Run one test or one suite: make test T='config validation'
T ?=

.PHONY: check test lint fmt fmt-check health clean

## check: everything CI would run
check: fmt-check lint test

## test: run the suite headless
test:
	$(NVIM_BIN) --clean --headless -l tests/runner.lua '$(T)'

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
	$(NVIM_BIN) --clean -u tests/minimal_init.lua -c 'checkhealth nvim-diff'

clean:
	rm -f luacheck-cache
