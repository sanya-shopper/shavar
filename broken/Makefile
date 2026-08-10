# broken/ — SHA-0 and SHA-1, and the attack that killed them.
#
# Nothing here is for production use. Both functions are cryptographically
# dead; this directory exists to show how.
CC      ?= cc
CFLAGS  ?= -std=c99 -O2 -Wall -Wextra -pedantic-errors -Wshadow -Wconversion \
           -Wsign-conversion -Wstrict-prototypes -Wmissing-prototypes -Werror
IFLAGS   = -Ic

BINS = c/sha01 attack/expansion attack/collide

all: $(BINS)

c/sha01: c/sha01.c c/main.c c/sha01.h
	$(CC) $(CFLAGS) $(IFLAGS) -o $@ c/sha01.c c/main.c

attack/expansion: attack/expansion.c c/sha01.c c/sha01.h
	$(CC) $(CFLAGS) $(IFLAGS) -o $@ attack/expansion.c c/sha01.c

attack/collide: attack/collide.c c/sha01.c c/sha01.h
	$(CC) $(CFLAGS) $(IFLAGS) -o $@ attack/collide.c c/sha01.c

check: all
	sh tests/run.sh

clean:
	rm -f $(BINS)

.PHONY: all check clean
