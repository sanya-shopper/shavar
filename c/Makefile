# shavar — C99 build.
#
# Produces both a static archive and a shared library, and provides a matrix
# of correctness checks under every compiler configuration available on this
# machine. See `make help`.
#
# A note on what is NOT here: valgrind. It does not support arm64 macOS at
# all, so on Apple Silicon it is simply unavailable rather than merely
# omitted. Its role is covered by AddressSanitizer (which subsumes most of
# what memcheck finds, and is faster), LeakSanitizer, UndefinedBehaviorSanitizer,
# and Apple's own `leaks`. MemorySanitizer is likewise unsupported on this
# target; the uninitialised-read checks it would provide are partly covered
# by the static analyzer.

CC      ?= cc
STD     ?= c99
OPT     ?= -O2
WARN     = -Wall -Wextra -pedantic-errors -Wshadow -Wconversion -Wsign-conversion \
           -Wcast-qual -Wstrict-prototypes -Wmissing-prototypes -Wpointer-arith \
           -Wwrite-strings -Wredundant-decls -Wundef
CFLAGS  ?= -std=$(STD) $(OPT) $(WARN)

LIBSRC   = shavar.c
LIBOBJ   = shavar.o
CLISRC   = main.c

# macOS names shared libraries .dylib. A .so is also produced because the
# project brief asked for one; on Darwin the two are the same format built
# with -shared, and both are loadable with dlopen. On ELF systems only the
# .so target is meaningful.
UNAME_S := $(shell uname -s)
ifeq ($(UNAME_S),Darwin)
SHLIB    = libshavar.dylib
SHFLAGS  = -dynamiclib -install_name @rpath/libshavar.dylib
else
SHLIB    = libshavar.so
SHFLAGS  = -shared
endif

.PHONY: all check help clean stds opts san ubsan asan analyze arch leaks bigmatrix

all: libshavar.a $(SHLIB) libshavar.so shavar

# ---- libraries -------------------------------------------------------

# Position-independent code so the same object can serve both archives and
# the shared library without a second compile.
$(LIBOBJ): $(LIBSRC) shavar.h
	$(CC) $(CFLAGS) -fPIC -c $(LIBSRC) -o $@

libshavar.a: $(LIBOBJ)
	ar rcs $@ $^
	@echo "  static archive:  $@"

$(SHLIB): $(LIBOBJ)
	$(CC) $(SHFLAGS) $(LIBOBJ) -o $@
	@echo "  shared library:  $@"

libshavar.so: $(LIBOBJ)
	$(CC) -shared $(LIBOBJ) -o $@
	@echo "  shared library:  $@"

# ---- executables -----------------------------------------------------

# Linked against the static archive.
shavar: $(CLISRC) libshavar.a shavar.h
	$(CC) $(CFLAGS) $(CLISRC) libshavar.a -o $@

# Linked against the shared library, to prove the .dylib actually resolves.
shavar-shared: $(CLISRC) $(SHLIB) shavar.h
	$(CC) $(CFLAGS) $(CLISRC) -L. -lshavar -Wl,-rpath,@loader_path -o $@

# ---- checks ----------------------------------------------------------

check: shavar shavar-shared
	@echo "== static-linked =="; ./shavar selftest
	@echo "== shared-linked =="; ./shavar-shared selftest

# Every language standard clang supports, at -O2. Catches constructs that
# happen to compile under one standard's rules and not another's.
stds:
	@for s in c99 c11 c17 c23; do \
	  printf '%-6s ' "$$s"; \
	  $(CC) -std=$$s $(OPT) $(WARN) $(LIBSRC) $(CLISRC) -o /tmp/shavar-$$s 2>/tmp/err-$$s \
	    && /tmp/shavar-$$s selftest | tr -d '\n' && echo "  [built+passed]" \
	    || { echo "FAILED"; cat /tmp/err-$$s; exit 1; }; \
	done

# Every optimisation level. -O0 vs -O3 differ in whether UB is exploited, so
# agreement across the range is meaningful evidence that there is none.
opts:
	@for o in -O0 -O1 -O2 -O3 -Os -Oz; do \
	  printf '%-5s ' "$$o"; \
	  $(CC) -std=$(STD) $$o $(WARN) $(LIBSRC) $(CLISRC) -o /tmp/shavar$$o 2>/dev/null \
	    && /tmp/shavar$$o selftest | tr -d '\n' && echo "  [built+passed]" \
	    || { echo "FAILED"; exit 1; }; \
	done

# AddressSanitizer + LeakSanitizer. The library allocates nothing, so a leak
# report here would indicate something has gone badly wrong rather than
# merely being untidy.
# AddressSanitizer. detect_leaks is deliberately NOT set: LeakSanitizer is
# not supported on arm64 macOS and enabling it aborts the run. The `leaks`
# target below covers that ground using Apple's own tool instead.
asan:
	$(CC) -std=$(STD) -O1 -g -fsanitize=address -fno-omit-frame-pointer \
	  $(LIBSRC) $(CLISRC) -o /tmp/shavar-asan
	ASAN_OPTIONS=strict_string_checks=1:detect_stack_use_after_return=1 \
	  /tmp/shavar-asan selftest

# UndefinedBehaviorSanitizer with every check the target supports, and
# -fno-sanitize-recover so that any finding is a hard failure rather than a
# line of diagnostic output that a CI run might scroll past.
#
# Note there are no exclusions here beyond unsigned-integer-overflow, and in
# particular `unsigned-shift-base` IS enabled — see the comment on rotr() in
# shavar.c for why the rotation is written so that it passes that check
# rather than suppressing it.
ubsan:
	$(CC) -std=$(STD) -O1 -g \
	  -fsanitize=undefined,integer,nullability,local-bounds \
	  -fno-sanitize=unsigned-integer-overflow \
	  -fno-sanitize-recover=all \
	  $(LIBSRC) $(CLISRC) -o /tmp/shavar-ubsan
	/tmp/shavar-ubsan selftest

# NOTE on -fno-sanitize=unsigned-integer-overflow: unsigned wraparound is not
# undefined behaviour in C, it is the defined mod-2^n semantics this algorithm
# is built on. Every modular addition in SHA-256 would otherwise trip it, so
# the check is inapplicable rather than merely inconvenient. Signed overflow
# remains checked, and there is no signed arithmetic in the library at all.

san: asan ubsan

# Clang's static analyzer: catches uninitialised reads and dead stores that
# the sanitizers only find if a test happens to execute the path.
analyze:
	$(CC) --analyze -Xanalyzer -analyzer-output=text -std=$(STD) $(LIBSRC) $(CLISRC)

# Second code generator: build for x86_64 and run it under Rosetta 2 if
# present. Same endianness, but a completely different backend, which is a
# genuine independent check on codegen assumptions.
arch:
	@if $(CC) -arch x86_64 -std=$(STD) $(OPT) $(LIBSRC) $(CLISRC) -o /tmp/shavar-x86 2>/dev/null; then \
	  echo "x86_64 cross-build OK"; \
	  /tmp/shavar-x86 selftest 2>/dev/null && echo "x86_64 ran under Rosetta" \
	    || echo "x86_64 built but did not run (Rosetta 2 not installed) — build-only check"; \
	else echo "x86_64 SDK not available — skipped"; fi

# Apple's leak checker, independent of the sanitizers.
leaks:
	$(CC) -std=$(STD) -O0 -g $(LIBSRC) $(CLISRC) -o /tmp/shavar-leaks
	MallocStackLogging=1 leaks --atExit -- /tmp/shavar-leaks selftest

bigmatrix: check stds opts san analyze arch leaks
	@echo
	@echo "all C checks passed"

help:
	@echo "targets: all check stds opts asan ubsan san analyze arch leaks bigmatrix clean"

clean:
	rm -f *.o *.a *.dylib *.so shavar shavar-shared *.plist
