VADER ?= ~/.vim/plugged/vader.vim

.PHONY: test
test: test-hooks
	@vim -u test/vimrc -c 'Vader! test/*.vader'

.PHONY: test-hooks
test-hooks:
	@command -v node >/dev/null 2>&1 \
		&& node test/hooks/status_writer.test.mjs \
		|| echo 'skipped: examples/hooks needs node'
