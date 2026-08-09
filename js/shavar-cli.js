#!/bin/sh
":" //; J="${SHAVAR_JSC:-/System/Library/Frameworks/JavaScriptCore.framework/Versions/A/Helpers/jsc}"; exec 9>&1; E="$("$J" "$0" -- --exit-protocol "$@" 2>&1 1>&9)"; R=$?; case "$E" in *@shavar-exit:*) C="${E##*@shavar-exit:}"; E="${E%@shavar-exit:*}";; *) C="$R";; esac; case "$C" in ''|*[!0-9]*) C="$R";; esac; [ -n "$E" ] && printf %s "$E" >&2; exit "$C"
/* =====================================================================
 * shavar-cli.js — the command-line driver, per ../spec/CLI.md.
 *
 * Two ways to run it, and the difference matters only for exit codes:
 *
 *   ./shavar-cli.js hash 616263 24              <- real POSIX exit codes
 *   jsc shavar-cli.js -- hash 616263 24         <- 0 on success, 3 on error
 *
 * ---------------------------------------------------------------------
 * WHY THE FIRST TWO LINES LOOK LIKE THAT
 * ---------------------------------------------------------------------
 * They are a shell/JavaScript polyglot, and they exist to solve a real
 * problem rather than to be clever.
 *
 * CLI.md requires three distinct exit codes: 0 success, 1 self-test
 * failure, 2 bad usage. JavaScript the *language* has no concept of a
 * process, so an exit code can only come from the host. Safari's
 * command-line engine, `jsc`, provides `quit()` — and, verified on this
 * machine, **`quit()` ignores its argument and always exits 0**:
 *
 *     $ jsc -e 'quit(2)'; echo $?
 *     0
 *
 * The only nonzero status `jsc` will ever produce is 3, which it returns
 * when the script dies on an uncaught exception. There is no
 * `process.exit`, no `os.exit`, no flag: `jsc --help` offers `-x`, which
 * merely *prints* the code it is about to return. So under a bare `jsc`
 * invocation the contract is unimplementable, full stop.
 *
 * The fix is to let a two-line shell wrapper own the exit status, while
 * keeping this a single file that `jsc` can also run directly.
 *
 *   Line 1  `#!/bin/sh`
 *           A shebang to the kernel. To a JavaScript parser it is a
 *           "hashbang comment", which the language permits on the first
 *           line precisely so that scripts can be executable.
 *
 *   Line 2  `":" //; <shell code>`
 *           To `/bin/sh`: run the null command `:` with the argument
 *           `//`, then the shell code after the semicolon.
 *           To JavaScript: the string literal `":"` as a statement,
 *           followed by a `//` line comment that swallows the rest.
 *           The shell code ends in `exit`, so the shell never reaches
 *           line 3 and never sees any JavaScript.
 *
 * The shell code re-invokes `jsc` on this same file, passing the flag
 * `--exit-protocol`. That flag tells the JavaScript side to report its
 * intended status as a sentinel line `@shavar-exit:N` on stderr instead
 * of trying to exit with it. The wrapper captures stderr (leaving stdout
 * untouched, via the `2>&1 1>&9` fd swap, so a digest or a trace still
 * streams straight through), strips the sentinel, forwards any real
 * diagnostics, and exits with N. If `jsc` dies before printing a
 * sentinel — i.e. this program has a bug — no sentinel is found and the
 * wrapper propagates jsc's own status, so genuine crashes stay visible
 * instead of being laundered into a clean exit.
 *
 * `SHAVAR_JSC` overrides the engine path if jsc lives elsewhere.
 *
 * Run under `jsc` directly and there is no wrapper to translate, so
 * errors surface as jsc's exit 3 with an explanatory line on stderr.
 * That is a limitation of the host, and it is stated rather than hidden.
 * ===================================================================== */

/* ---------------------------------------------------------------------
 * Capturing argv. This MUST happen at the top level.
 *
 * `jsc` hands a script its arguments in a global called `arguments`,
 * holding everything after the `--` separator. The trap for anyone used
 * to Python's `sys.argv` or C's `argv` is that `arguments` is also the
 * name of the implicit per-call arguments object inside every ordinary
 * JavaScript function. Read it one line deeper, inside a `function`, and
 * you silently get that function's own parameters instead. So it is
 * copied into a normal variable here, in global scope, before anything
 * else runs.
 *
 * Unlike C's argv, there is no program name in slot 0: `arguments[0]` is
 * already the first real argument.
 * ------------------------------------------------------------------- */
var ARGV = (typeof arguments === "undefined")
  ? []
  : Array.prototype.slice.call(arguments);

(function main(argv) {
  "use strict";

  /* --- exit-status plumbing (see the header) ----------------------- */

  var exitProtocol = false;
  if (argv[0] === "--exit-protocol") {
    exitProtocol = true;
    argv = argv.slice(1);
  }

  /** Write one line to stderr. jsc's `printErr` is line-oriented: it
   *  appends the newline itself, like Python's `print(..., file=sys.stderr)`
   *  rather than C's `fputs`. */
  const warn = (msg) => printErr(msg);

  /** Write text to stdout. jsc's `print` also appends a newline, so any
   *  text that already ends in one has it trimmed first — otherwise every
   *  trace would gain a spurious blank final line and fail the
   *  byte-for-byte cross-test. */
  const emit = (text) => print(text.charAt(text.length - 1) === "\n"
    ? text.slice(0, -1)
    : text);

  /** Terminate with the given status, by whichever route is available. */
  function finish(code) {
    if (exitProtocol) {
      printErr(`@shavar-exit:${code}`);
      quit();                       // wrapper supplies the real status
    }
    if (code === 0) quit();
    /* No wrapper. jsc's quit() cannot carry a status and would report
     * success, which for a failing run would be an outright lie — worse
     * than an ugly exit code. An uncaught exception at least guarantees
     * nonzero (jsc uses 3). */
    warn(`shavar: intended exit status ${code}; jsc's quit() cannot carry one, ` +
         `so this run aborts and jsc reports 3 instead. ` +
         `Execute the script directly (./shavar-cli.js ...) for true exit codes.`);
    throw new Error(`shavar: exit ${code}`);
  }

  /* --- locating and loading the implementation --------------------- */

  /**
   * jsc's `load()` resolves paths against the current working directory,
   * not against the running script, so `load("shavar.js")` breaks the
   * moment anyone runs this from the repository root. There is no
   * `__dirname` and no `import.meta.url` in a classic script, but the
   * invocation path does appear in a stack trace, e.g.
   *
   *     global code@js/shavar-cli.js:12:3
   *
   * so it can be recovered from a throwaway Error. Candidates are tried
   * in order and the first that loads wins.
   */
  function locateLibrary() {
    const frame = (new Error().stack || "").split("\n")[0] || "";
    const at = frame.lastIndexOf("@");
    const path = (at >= 0 ? frame.slice(at + 1) : frame).replace(/:\d+:\d+$/, "");
    const slash = path.lastIndexOf("/");
    const dir = slash >= 0 ? path.slice(0, slash + 1) : "";
    return [`${dir}shavar.js`, "shavar.js", "js/shavar.js"];
  }

  if (typeof SHAVAR === "undefined") {
    let loaded = false;
    for (const candidate of locateLibrary()) {
      try {
        load(candidate);
        loaded = true;
        break;
      } catch (e) { /* try the next candidate */ }
    }
    if (!loaded || typeof SHAVAR === "undefined") {
      warn("shavar: cannot locate shavar.js next to this script");
      finish(2);
    }
  }

  const S = SHAVAR;

  /* --- argument parsing -------------------------------------------- */

  const USAGE = [
    "usage: shavar-cli.js <command> [args]",
    "  hash  <hex> <nbits> [rounds]",
    "  trace <hex> <nbits> [blockidx] [rounds]",
    "  selftest",
    "",
    "<hex> is 2*ceil(nbits/8) hex digits, or - for the empty message.",
    "When nbits % 8 != 0 the final byte's low bits must be zero.",
  ].join("\n");

  /**
   * Parse a decimal non-negative integer, strictly.
   *
   * `parseInt` is not usable here: it stops at the first character it
   * does not like and returns what it has, so `parseInt("12abc")` is 12
   * and `parseInt("")` is NaN. `Number("12abc")` is NaN but `Number("")`
   * is 0 and `Number(" 7 ")` is 7. Neither matches "a decimal
   * non-negative integer", so the shape is checked with a regexp first
   * and only then converted.
   */
  function parseCount(text, what) {
    if (!/^[0-9]+$/.test(text)) {
      warn(`shavar: ${what} must be a decimal non-negative integer, got "${text}"`);
      finish(2);
    }
    const n = Number(text);
    if (!Number.isSafeInteger(n)) {
      warn(`shavar: ${what} ${text} exceeds ${S.MAX_BITS}, the largest integer a ` +
           `JavaScript number represents exactly`);
      finish(2);
    }
    return n;
  }

  /** Decode `<hex> <nbits>` into a byte array, enforcing CLI.md's rules. */
  function parseMessage(hexText, nbitsText) {
    const nbits = parseCount(nbitsText, "nbits");
    let bytes;
    try {
      bytes = S.hexToBytes(hexText);
    } catch (e) {
      warn(`shavar: ${e.message}`);
      finish(2);
    }
    const need = Math.ceil(nbits / 8);
    if (bytes.length !== need) {
      warn(`shavar: nbits=${nbits} needs ceil(${nbits}/8) = ${need} byte(s), ` +
           `but ${bytes.length} were given`);
      finish(2);
    }
    try {
      S.checkTrailingBits(bytes, nbits);      // SPEC.md §5.1, never masked
    } catch (e) {
      warn(`shavar: ${e.message}`);
      finish(2);
    }
    return { bytes, nbits };
  }

  function parseRounds(text) {
    if (text === undefined) return S.ROUNDS;
    const r = parseCount(text, "rounds");
    if (r < 1 || r > S.ROUNDS) {
      warn(`shavar: rounds must be in 1..${S.ROUNDS}, got ${r}`);
      finish(2);
    }
    return r;
  }

  /* --- subcommands -------------------------------------------------- */

  function cmdHash(args) {
    if (args.length < 2 || args.length > 3) {
      warn("shavar: hash takes <hex> <nbits> [rounds]");
      finish(2);
    }
    const [hexText, nbitsText, roundsText] = args;   // array destructuring
    const { bytes, nbits } = parseMessage(hexText, nbitsText);
    const rounds = parseRounds(roundsText);
    emit(S.hashHex(bytes, nbits, { rounds }));       // 64 lowercase hex + \n
    finish(0);
  }

  function cmdTrace(args) {
    if (args.length < 2 || args.length > 4) {
      warn("shavar: trace takes <hex> <nbits> [blockidx] [rounds]");
      finish(2);
    }
    const [hexText, nbitsText, idxText, roundsText] = args;
    const { bytes, nbits } = parseMessage(hexText, nbitsText);
    const idx = idxText === undefined ? 0 : parseCount(idxText, "blockidx");
    const rounds = parseRounds(roundsText);

    const nblocks = S.paddedBlocks(nbits);
    if (idx >= nblocks) {
      warn(`shavar: blockidx ${idx} out of range; the padded message has ` +
           `${nblocks} block(s), so valid indices are 0..${nblocks - 1}`);
      finish(2);
    }
    emit(S.formatTrace(S.traceBlock(bytes, nbits, idx, { rounds })));
    finish(0);
  }

  function cmdSelftest(args) {
    if (args.length !== 0) {
      warn("shavar: selftest takes no arguments");
      finish(2);
    }
    const { total, passed, failures } = S.selftest();
    if (failures.length === 0) {
      emit(`ok ${passed}`);
      finish(0);
    }
    /* One line per failing vector, tab-separated for the same reason the
     * trace is: it stays greppable and diffable. These go to stdout
     * because CLI.md lists them as the output of `selftest`, alongside
     * the `ok <n>` line they replace, rather than as diagnostics. */
    for (const f of failures) {
      emit(`FAIL\t${f.name}\t${f.input}\t${f.expect}\t${f.actual}`);
    }
    warn(`shavar: ${failures.length} of ${total} vectors failed`);
    finish(1);
  }

  /* --- dispatch ------------------------------------------------------ */

  const [command, ...rest] = argv;   // rest parameter: the remaining args

  switch (command) {
    case "hash":     cmdHash(rest); break;
    case "trace":    cmdTrace(rest); break;
    case "selftest": cmdSelftest(rest); break;
    case undefined:
      warn(USAGE);
      finish(2);
      break;
    default:
      warn(`shavar: unknown command "${command}"`);
      warn(USAGE);
      finish(2);
  }

  /* Unreachable: every path above ends in finish(). */
  finish(0);
})(ARGV);
