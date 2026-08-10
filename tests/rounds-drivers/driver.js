// Rounds-contract driver for js/shavar.js. See tests/rounds.sh.
(function () {
  "use strict";
  var isNode = typeof process !== "undefined" && process.versions && process.versions.node;
  var argv, readFile, emit;
  if (isNode) {
    var fs = require("fs");
    argv = process.argv.slice(2);
    readFile = function (p) { return fs.readFileSync(p, "utf8"); };
    emit = function (s) { process.stdout.write(s + "\n"); };
    require(__dirname + "/../../js/shavar.js");
  } else {
    argv = arguments; readFile = read; emit = print;
    load("./js/shavar.js");
  }
  var msg = SHAVAR.hexToBytes("616263");
  readFile(argv[0]).split("\n").forEach(function (line) {
    if (!line || line.charAt(0) === "#") return;
    var r = parseInt(line.split("\t")[0], 10);
    if (isNaN(r)) return;
    try { emit(r + "\taccepted\t" + SHAVAR.bytesToHex(SHAVAR.hashEx(msg, 24, { rounds: r }))); }
    catch (e) {
      if (!(e instanceof SHAVAR.ShavarError)) throw e;
      emit(r + "\trejected\t-");
    }
  });
})();
