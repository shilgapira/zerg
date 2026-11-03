SHELL := /bin/bash

NAME ?= Spawn: Dry Run

.PHONY: help check test dry-run clean

help:
	@echo "make check     syntax-check the shell scripts, AppleScript heredocs and JXA"
	@echo "make test      run tests/launcher_test.sh and tests/desktop_compact_test.sh against throwaway folders"
	@echo "make dry-run   detect terminal and tty and print the launcher, without opening a tab (NAME=...)"
	@echo "make clean     remove leftover launchers and shield state from TMPDIR"

check:
	@for f in scripts/*.sh scripts/lib/*.sh scripts/terminals/*.sh tests/*.sh; do /bin/bash -n "$$f" || exit 1; done
	@tmp="$$(mktemp -d)"; trap 'rm -rf "$$tmp"' EXIT; \
	for f in scripts/*.sh scripts/lib/*.sh scripts/terminals/*.sh; do \
	  awk -v out="$$tmp/$$(basename "$$f" .sh)" ' \
	    /<<.APPLESCRIPT./ { n++; file = out "-" n ".applescript"; next } \
	    /<<.JXA./ { n++; file = out "-" n ".js"; next } \
	    /^(APPLESCRIPT|JXA)$$/ { file = ""; next } \
	    file != "" { print > file }' "$$f"; \
	done; \
	for s in "$$tmp"/*.applescript "$$tmp"/*.js scripts/lib/*.js; do \
	  [ -e "$$s" ] || continue; \
	  lang=AppleScript; case "$$s" in *.js) lang=JavaScript ;; esac; \
	  osacompile -l "$$lang" -o "$$tmp/out.scpt" "$$s" 2>&1 | sed "s|^|$$(basename "$$s"): |"; \
	  [ "$${PIPESTATUS[0]}" = 0 ] || exit 1; \
	done
	@echo "check ok"

test:
	@/bin/bash tests/launcher_test.sh
	@bash tests/desktop_compact_test.sh

dry-run:
	@prompt="$$(mktemp)"; trap 'rm -f "$$prompt"' EXIT; echo "Dry run." > "$$prompt"; \
	scripts/launch.sh --name "$(NAME)" --prompt-file "$$prompt" --dry-run

clean:
	@rm -rf "$${TMPDIR:-/tmp}/claude-spawn"
	@echo "removed $${TMPDIR:-/tmp}/claude-spawn"
