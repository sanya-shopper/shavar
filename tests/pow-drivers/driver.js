// PoW driver for js/shavar.js. See tests/pow.sh.
//
// Reads the vector file named on the command line and writes one
// `id <TAB> met|unmet|invalid` line per vector. Marshalling only: every
// decision comes from SHAVAR.powCheck.
//
// Runs under both jsc (Safari's engine, where `read` and `arguments` exist)
// and node (where they do not), because CI has no jsc. The two are told apart
// by feature detection rather than by a flag, so neither host is privileged.

(function () {
  "use strict";

  var isNode = typeof process !== "undefined" && process.versions &&
               process.versions.node;

  var argv, readFile, write;
  if (isNode) {
    var fs = require("fs");
    argv = process.argv.slice(2);
    readFile = function (p) { return fs.readFileSync(p, "utf8"); };
    write = function (s) { process.stdout.write(s); };
    require(__dirname + "/../../js/shavar.js");
  } else {
    argv = arguments; // jsc puts script arguments here
    readFile = read;  // jsc builtin
    write = function (s) { print(s.replace(/\n$/, "")); };
    load("./js/shavar.js");
  }

  if (argv.length !== 1) {
    throw new Error("usage: driver.js VECTORS.tsv");
  }

  var lines = readFile(argv[0]).split("\n");
  var out = [];
  for (var i = 0; i < lines.length; i++) {
    var line = lines[i];
    if (!line || line.charAt(0) === "#") continue;
    var f = line.split("\t");
    var id = f[0], dhex = f[1], nbhex = f[2];
    if (!id || !dhex || !nbhex) continue;

    var digest = SHAVAR.hexToBytes(dhex);
    var nbits = parseInt(nbhex, 16);
    var verdict;
    try {
      verdict = SHAVAR.powCheck(digest, nbits) ? "met" : "unmet";
    } catch (e) {
      if (!(e instanceof SHAVAR.ShavarError)) throw e;
      verdict = "invalid";
    }
    out.push(id + "\t" + verdict);
  }
  write(out.join("\n") + "\n");
})();
