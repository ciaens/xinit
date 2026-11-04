# Xinit 2 entry points. Tests: docs/TESTING.md. Test images: docs/test-env.md.

PREFIX ?= /usr/local
DESTDIR ?=
VARIANT ?= tomcat10-pgsql

BINDIR = $(DESTDIR)$(PREFIX)/bin
# bin/xinit finds its libraries in ../lib/xinit, so the two must stay side by side.
LIBDIR = $(DESTDIR)$(PREFIX)/lib/xinit
LIBS = $(notdir $(wildcard lib/xinit/*.sh))

.PHONY: help lint test-unit test-integration test images install uninstall

help:
	@echo "make lint                    shellcheck the new tree and the tests"
	@echo "make test-unit               bats unit tests (no Docker)"
	@echo "make test-integration        integration tests in a test container [VARIANT=$(VARIANT)]"
	@echo "make test                    lint + unit + integration [VARIANT=$(VARIANT)]"
	@echo "make images                  build every test image listed in tests/env/variants"
	@echo "make install / uninstall     [PREFIX=$(PREFIX)] [DESTDIR=]"

lint:
	tests/run.sh --suite lint

test-unit:
	tests/run.sh --suite unit

test-integration:
	tests/run.sh --suite integration --variant $(VARIANT)

test:
	tests/run.sh --variant $(VARIANT)

images:
	set -e; for v in $$(grep -v '^#' tests/env/variants); do tests/env/xwiki-env.sh build $$v; done

install:
	install -d $(BINDIR) $(LIBDIR)
	install -m 0755 bin/xinit $(BINDIR)/xinit
	install -m 0644 $(addprefix lib/xinit/,$(LIBS)) $(LIBDIR)/

uninstall:
	rm -f $(BINDIR)/xinit $(addprefix $(LIBDIR)/,$(LIBS))
	-rmdir $(LIBDIR)
