VADER ?= ~/.vim/plugged/vader.vim

.PHONY: test
test:
	@vim -u test/vimrc -c 'Vader! test/*.vader'
