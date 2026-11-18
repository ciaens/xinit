# Xinit 2 entry points. Tests: docs/TESTING.md. Test images: docs/test-env.md.

PREFIX ?= /usr/local
DESTDIR ?=
VARIANT ?= tomcat10-pgsql

BINDIR = $(DESTDIR)$(PREFIX)/bin
# bin/xinit finds its libraries in ../lib/xinit, so the two must stay side by side.
LIBDIR = $(DESTDIR)$(PREFIX)/lib/xinit
# Paths relative to lib/xinit: core.sh, profiles/war.sh...
LIBS = $(patsubst lib/xinit/%,%,$(wildcard lib/xinit/*.sh lib/xinit/*/*.sh))
LIBSUBDIRS = $(sort $(filter-out ./,$(dir $(LIBS))))

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
	install -d $(BINDIR) $(LIBDIR) $(addprefix $(LIBDIR)/,$(LIBSUBDIRS))
	install -m 0755 bin/xinit $(BINDIR)/xinit
	set -e; for f in $(LIBS); do install -m 0644 lib/xinit/$$f $(LIBDIR)/$$f; done

uninstall:
	rm -f $(BINDIR)/xinit $(addprefix $(LIBDIR)/,$(LIBS))
	-rmdir $(addprefix $(LIBDIR)/,$(LIBSUBDIRS)) $(LIBDIR)
