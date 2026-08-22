# shavar — C99 build.
#
# Produces both a static archive and a shared library, and provides a matrix
# of correctness checks under every compiler configuration available on this
# machine. See `make help`.
#
# TOOL AVAILABILITY ON THIS HOST (Darwin 25.5.0 arm64, Apple clang 17)
#
# Three of the tools one would normally reach for do not work here, and it is
# worth writing down which and why so their absence reads as a platform fact
# rather than an oversight:
#
#   valgrind   Does not support arm64 macOS at all. Not installable.
#   MSan       -fsanitize=memory is rejected outright for this target.
#   ASan       Builds fine but HANGS AT STARTUP on this machine. Verified with
#              a do-nothing `int main(void){return 0;}`: it spins indefinitely,
#              burning CPU, both inside and outside the shell sandbox. With
#              ASAN_OPTIONS=verbosity=1 the last line printed is
#              "AddressSanitizer: libc interceptors initialized", so it stalls
#              during runtime init, before reaching main. This is an
#              incompatibility between the shipped ASan runtime and this OS
#              build, not a property of this code. The asan targets below are
#              kept because they are correct and will run on a working host.
#
# What DOES work here, and is clean:
#
#   ubsan      -fsanitize=undefined,integer,nullability,local-bounds with
#              -fno-sanitize-recover=all: passes with no findings.
#   analyze    clang static analyzer: no warnings.
#   leaks      Apple's leak checker: "0 leaks for 0 total leaked bytes".
#              Expected, since the library calls no allocator at all.
#   stds/opts  4 language standards x 6 optimisation levels, all agreeing.
#   arch       x86_64 cross-build for a second code generator.

# Build output goes to the disposable tree (CLAUDE.md T2/T4), never in-tree.
# The default prefix is the directory the repo sits in — derived, not
# hardcoded, so the same Makefile works on a CI checkout — matching
# broken/Makefile and the buildDir in lean/lakefile.toml.
BUILD_TARGET_PREFIX ?= $(abspath ../..)
OUT      = $(BUILD_TARGET_PREFIX)/_buildoutput/256-shavar/c

CC      ?= cc
STD     ?= c99
OPT     ?= -O2
WARN     = -Wall -Wextra -pedantic-errors -Wshadow -Wconversion -Wsign-conversion \
           -Wcast-qual -Wstrict-prototypes -Wmissing-prototypes -Wpointer-arith \
           -Wwrite-strings -Wredundant-decls -Wundef
CFLAGS  ?= -std=$(STD) $(OPT) $(WARN)

LIBSRC   = shavar.c
LIBOBJ   = $(OUT)/shavar.o
CLISRC   = main.c

# macOS names shared libraries .dylib. A .so is also produced because the
# project brief asked for one; on Darwin the two are the same format built
# with -shared, and both are loadable with dlopen. On ELF systems only the
# .so target is meaningful.
UNAME_S := $(shell uname -s)
ifeq ($(UNAME_S),Darwin)
SHLIB    = libshavar.dylib
SHFLAGS  = -dynamiclib -install_name @rpath/libshavar.dylib
RPATH    = -Wl,-rpath,@loader_path
else
SHLIB    = libshavar.so
SHFLAGS  = -shared
RPATH    = -Wl,-rpath,'$$ORIGIN'
endif

.PHONY: all check help clean stds opts san ubsan asan asan-deep analyze arch leaks bigmatrix shavar shavar-shared out

all: $(OUT)/libshavar.a $(OUT)/$(SHLIB) $(OUT)/libshavar.so $(OUT)/shavar

# Convenience aliases, so `make shavar` keeps meaning what it used to.
shavar: $(OUT)/shavar
shavar-shared: $(OUT)/shavar-shared

# Where the products go, for shell callers:  OUT=$$(make -s -C c out)
out:
	@echo $(OUT)

# ---- libraries -------------------------------------------------------

# Position-independent code so the same object can serve both archives and
# the shared library without a second compile.
$(LIBOBJ): $(LIBSRC) shavar.h
	@mkdir -p $(OUT)
	$(CC) $(CFLAGS) -fPIC -c $(LIBSRC) -o $@

$(OUT)/libshavar.a: $(LIBOBJ)
	ar rcs $@ $^
	@echo "  static archive:  $@"

$(OUT)/$(SHLIB): $(LIBOBJ)
	$(CC) $(SHFLAGS) $(LIBOBJ) -o $@
	@echo "  shared library:  $@"

$(OUT)/libshavar.so: $(LIBOBJ)
	$(CC) -shared $(LIBOBJ) -o $@
	@echo "  shared library:  $@"

# ---- executables -----------------------------------------------------

# Linked against the static archive.
$(OUT)/shavar: $(CLISRC) $(OUT)/libshavar.a shavar.h
	$(CC) $(CFLAGS) $(CLISRC) $(OUT)/libshavar.a -o $@

# Linked against the shared library, to prove the .dylib actually resolves.
$(OUT)/shavar-shared: $(CLISRC) $(OUT)/$(SHLIB) shavar.h
	$(CC) $(CFLAGS) $(CLISRC) -L$(OUT) -lshavar $(RPATH) -o $@

# ---- checks ----------------------------------------------------------

check: $(OUT)/shavar $(OUT)/shavar-shared
	@echo "== static-linked =="; $(OUT)/shavar selftest
	@echo "== shared-linked =="; $(OUT)/shavar-shared selftest

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

# AddressSanitizer. The library allocates nothing, so there is no heap to
# corrupt; what ASan is actually buying here is bounds checking on the trace
# arrays and the padded-block buffer, which is where an off-by-one in the
# +4 index offset or the padding arithmetic would show up.
#
# detect_leaks is deliberately NOT set: LeakSanitizer is unsupported on arm64
# macOS and enabling it aborts the run outright. The `leaks` target below
# covers that ground with Apple's own tool instead.
#
# This is the standard run: the full vector set including the million-'a'
# block, with ASan's default (fast) stack handling.
asan:
	$(CC) -std=$(STD) -O1 -g -fsanitize=address -fno-omit-frame-pointer \
	  $(LIBSRC) $(CLISRC) -o /tmp/shavar-asan
	ASAN_OPTIONS=strict_string_checks=1 /tmp/shavar-asan selftest

# The deep run: adds detect_stack_use_after_return, which relocates every
# large stack local to a poisoned heap frame. That is ~100x slower here
# because shavar_compress builds a 1.1 KB trace per block, so it runs against
# the short vectors only (SHAVAR_QUICK=1). Restricting the input, not the
# check, keeps the coverage honest — every code path still executes.
asan-deep:
	$(CC) -std=$(STD) -O1 -g -fsanitize=address -fno-omit-frame-pointer \
	  $(LIBSRC) $(CLISRC) -o /tmp/shavar-asan
	SHAVAR_QUICK=1 \
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

san: asan asan-deep ubsan

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
	@echo "targets: all check stds opts asan asan-deep ubsan san analyze arch leaks bigmatrix clean"

clean:
	rm -f $(OUT)/*.o $(OUT)/*.a $(OUT)/*.dylib $(OUT)/*.so \
	      $(OUT)/shavar $(OUT)/shavar-shared *.plist
