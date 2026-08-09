#!/usr/bin/env node
/* CI-only adapter: drive the unmodified js/shavar.js under Node.
 *
 * WHY THIS EXISTS
 * ---------------
 * The real JavaScript entry point is js/shavar-cli.js, which targets `jsc`,
 * JavaScriptCore — Safari's own engine, and the deployment target this
 * project actually cares about. That is the file to read and the one that is
 * covered by the macOS CI job.
 *
 * But no jsc exists on a Linux CI runner, and jsc has a specific quirk the
 * committed CLI works around: its `quit()` ignores its argument and always
 * exits 0, so honouring spec/CLI.md's 0/1/2 exit codes there requires a
 * shell/JS polyglot wrapper. Node has none of those problems, so this
 * adapter is deliberately trivial.
 *
 * WHAT IT IS NOT: a second implementation. It loads js/shavar.js verbatim and
 * does nothing but marshal argv and exit codes. If it and shavar-cli.js ever
 * disagreed, the cross-check would catch it, because both are compared
 * against the C reference on the same inputs.
 *
 * Node built-ins are used freely here. The project's no-modules rule
 * constrains the seven implementations, not the test tooling.
 */
"use strict";

const fs = require("fs");
const vm = require("vm");
const path = require("path");

// Run shavar.js in this context so that its `root.SHAVAR = ...` lands on our
// global object, exactly as a browser <script> tag would.
const src = fs.readFileSync(path.join(__dirname, "..", "js", "shavar.js"), "utf8");
vm.runInThisContext(src, { filename: "js/shavar.js" });

const S = globalThis.SHAVAR;
if (!S) {
  process.stderr.write("node-cli: js/shavar.js did not define SHAVAR\n");
  process.exit(2);
}

const argv = process.argv.slice(2);
const die = (msg) => {
  process.stderr.write("shavar: " + msg + "\n");
  process.exit(2);
};

// spec/CLI.md: a decimal non-negative integer, and nothing else. Node's
// Number() and parseInt() are both too permissive to use directly.
const uint = (s) => {
  if (!/^[0-9]+$/.test(s)) die("bad number '" + s + "'");
  return Number(s);
};

// "-" denotes a zero-byte message.
const bytes = (hex) => {
  if (hex === "-") return new Uint8Array(0);
  if (!/^([0-9a-fA-F]{2})*$/.test(hex)) die("malformed hex");
  return S.hexToBytes(hex);
};

try {
  const cmd = argv[0];

  if (cmd === "hash" && argv.length >= 3) {
    const msg = bytes(argv[1]);
    const nbits = uint(argv[2]);
    const rounds = argv.length >= 4 ? uint(argv[3]) : S.ROUNDS;
    if (msg.length !== Math.ceil(nbits / 8)) die("hex byte count does not match bit count");
    process.stdout.write(S.hashHex(msg, nbits, { rounds }) + "\n");
    process.exit(0);
  }

  if (cmd === "trace" && argv.length >= 3) {
    const msg = bytes(argv[1]);
    const nbits = uint(argv[2]);
    const idx = argv.length >= 4 ? uint(argv[3]) : 0;
    const rounds = argv.length >= 5 ? uint(argv[4]) : S.ROUNDS;
    if (msg.length !== Math.ceil(nbits / 8)) die("hex byte count does not match bit count");
    process.stdout.write(S.formatTrace(S.traceBlock(msg, nbits, idx, { rounds })));
    process.exit(0);
  }

  if (cmd === "selftest" && argv.length === 1) {
    const r = S.selftest();
    if (r.failures && r.failures.length) {
      for (const f of r.failures) process.stderr.write("FAIL " + JSON.stringify(f) + "\n");
      process.exit(1);
    }
    process.stdout.write("ok " + r.passed + "\n");
    process.exit(0);
  }

  process.stderr.write(
    "usage: node-cli.js hash <hex|-> <nbits> [rounds]\n" +
      "       node-cli.js trace <hex|-> <nbits> [blockidx] [rounds]\n" +
      "       node-cli.js selftest\n"
  );
  process.exit(2);
} catch (e) {
  // A ShavarError is a rejected input (bad trailing bits, bad length): that
  // is exit 2 per CLI.md, not a crash.
  process.stderr.write("shavar: " + (e && e.message ? e.message : String(e)) + "\n");
  process.exit(2);
}
