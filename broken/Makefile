# broken/ — SHA-0 and SHA-1, and the attack that killed them.
#
# Nothing here is for production use. Both functions are cryptographically
# dead; this directory exists to show how.
# Build output goes to the disposable tree (CLAUDE.md T2/T4). The default
# prefix is the directory the repo sits in — derived, not hardcoded, so the
# same Makefile works on a CI checkout — matching where the relative buildDir
# in lean/lakefile.toml puts the Lean half.
BUILD_TARGET_PREFIX ?= $(abspath ../..)
OUT      = $(BUILD_TARGET_PREFIX)/_buildoutput/256-shavar/broken

CC      ?= cc
CFLAGS  ?= -std=c99 -O2 -Wall -Wextra -pedantic-errors -Wshadow -Wconversion \
           -Wsign-conversion -Wstrict-prototypes -Wmissing-prototypes -Werror
IFLAGS   = -Ic

BINS = $(OUT)/sha01 $(OUT)/expansion $(OUT)/collide

all: $(BINS)

$(OUT)/sha01: c/sha01.c c/main.c c/sha01.h
	@mkdir -p $(OUT)
	$(CC) $(CFLAGS) $(IFLAGS) -o $@ c/sha01.c c/main.c

$(OUT)/expansion: attack/expansion.c c/sha01.c c/sha01.h
	@mkdir -p $(OUT)
	$(CC) $(CFLAGS) $(IFLAGS) -o $@ attack/expansion.c c/sha01.c

$(OUT)/collide: attack/collide.c c/sha01.c c/sha01.h
	@mkdir -p $(OUT)
	$(CC) $(CFLAGS) $(IFLAGS) -o $@ attack/collide.c c/sha01.c

check: all
	sh tests/run.sh

clean:
	rm -f $(BINS)

.PHONY: all check clean
