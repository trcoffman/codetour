NVIM ?= nvim
PLENARY_DIR ?= .tests/plenary.nvim
TESTS ?= tests/codetour

.PHONY: test deps clean

test: deps
	PLENARY_DIR=$(PLENARY_DIR) XDG_DATA_HOME=.tests/data XDG_STATE_HOME=.tests/state \
	$(NVIM) --headless --noplugin -u tests/minimal_init.lua \
		-c "PlenaryBustedDirectory $(TESTS) { minimal_init = 'tests/minimal_init.lua', sequential = true, timeout = 60000 }"

deps: $(PLENARY_DIR)

$(PLENARY_DIR):
	git clone --depth 1 https://github.com/nvim-lua/plenary.nvim $(PLENARY_DIR)

clean:
	rm -rf .tests
