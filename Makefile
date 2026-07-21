# shell-json — A pure-bash JSON parser, serializer, and query engine
#
# Part of shell-json (https://github.com/quintin/shell-json)
#
# Targets:
#   install   — Copy library files to $(PREFIX)/lib/shell-json/
#   uninstall — Remove installed files
#   bundle    — Create a single distributable json.sh

PREFIX   ?= /usr/local
LIBDIR    = $(PREFIX)/lib/shell-json
BUNDLE    = dist/json.sh

SRC       = $(wildcard src/*.sh)
BUNDLE_ORDER = \
	src/error.sh \
	src/ast.sh \
	src/string.sh \
	src/number.sh \
	src/lexer.sh \
	src/parser.sh \
	src/object.sh \
	src/array.sh \
	src/writer.sh \
	src/query.sh \
	src/json.sh

# ── Install ────────────────────────────────────────────────────────────

.PHONY: install

install:
	install -d "$(DESTDIR)$(LIBDIR)"
	install -m 644 $(SRC) "$(DESTDIR)$(LIBDIR)/"
	@echo "Installed shell-json to $(DESTDIR)$(LIBDIR)"
	@echo ""
	@echo "Usage: source $(DESTDIR)$(LIBDIR)/json.sh"
	@echo ""

# ── Uninstall ──────────────────────────────────────────────────────────

.PHONY: uninstall

uninstall:
	rm -rf "$(DESTDIR)$(LIBDIR)"
	@echo "Removed $(DESTDIR)$(LIBDIR)"

# ── Bundle (single-file distribution) ──────────────────────────────────

.PHONY: bundle

bundle: $(BUNDLE)

$(BUNDLE): $(BUNDLE_ORDER) | dist/
	{ \
		echo '#!/usr/bin/env bash'; \
		echo '# shell-json — single-file bundle'; \
		echo "# Version: $$(cat VERSION 2>/dev/null || echo 'unknown')"; \
		echo "# Generated: $$(date '+%Y-%m-%d')"; \
		echo ''; \
		for f in $(BUNDLE_ORDER); do \
			echo "# --- $$(basename "$$f") ---"; \
			case "$$f" in \
				*/json.sh) \
					# json.sh: remove sourcing of other modules (they're inlined above) \
					sed '/^source /d' "$$f" ;; \
				*) \
					# Other modules: remove #!/ header lines, keep everything else \
					sed '1{/^#!/d}' "$$f" ;; \
			esac; \
			echo ''; \
		done; \
	} > "$@"
	chmod +x "$@"
	@echo "Created $(BUNDLE)"
	@echo "  Usage: source $(BUNDLE)"
	@echo "  Size:  $$(wc -c < "$@") bytes"

dist/:
	mkdir -p dist

# ── Clean ──────────────────────────────────────────────────────────────

.PHONY: clean

clean:
	rm -rf dist/

# ── Help ───────────────────────────────────────────────────────────────

.PHONY: help

help:
	@echo "shell-json Makefile"
	@echo ""
	@echo "Targets:"
	@echo "  make install   — Install to \$${PREFIX}/lib/shell-json/ ($(PREFIX))"
	@echo "  make uninstall — Remove installed files"
	@echo "  make bundle    — Create single-file dist/json.sh"
	@echo "  make clean     — Remove build artifacts"
	@echo ""
