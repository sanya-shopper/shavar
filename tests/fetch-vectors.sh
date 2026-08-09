#!/bin/sh
#
# fetch-vectors.sh — (re)download the NIST CAVP SHAVS test vectors.
#
# The extracted .rsp files are committed to tests/vectors/, so the test suite
# runs offline and a checkout at any commit is testable against the same
# vectors.  This script exists to record exactly where they came from and to
# make refreshing them a single command, not because the suite needs network.
#
# Source: NIST Cryptographic Algorithm Validation Program, Secure Hash
# Algorithm Validation System (SHAVS) response files, CAVS 11.0, generated
# 2011-03-15.  Retrieved 2026-08-09 from:
#
#   https://csrc.nist.gov/CSRC/media/Projects/Cryptographic-Algorithm-Validation-Program/documents/shs/shabytetestvectors.zip
#   https://csrc.nist.gov/CSRC/media/Projects/Cryptographic-Algorithm-Validation-Program/documents/shs/shabittestvectors.zip
#
# Only the four SHA-256 files are extracted; the archives also carry SHA-1,
# SHA-224, SHA-384, SHA-512 and Monte Carlo files that this project does not
# use.  The Monte Carlo files are deliberately skipped: they specify 100 x 1000
# chained hash iterations, which through a per-invocation command-line
# interface would be 300000 process spawns for no coverage that the short and
# long message files do not already give.
#
# Usage: tests/fetch-vectors.sh [--verify-only]

set -eu
. "$(dirname "$0")/lib/common.sh"

BYTE_URL=https://csrc.nist.gov/CSRC/media/Projects/Cryptographic-Algorithm-Validation-Program/documents/shs/shabytetestvectors.zip
BIT_URL=https://csrc.nist.gov/CSRC/media/Projects/Cryptographic-Algorithm-Validation-Program/documents/shs/shabittestvectors.zip

VERIFY_ONLY=0
[ "${1:-}" = "--verify-only" ] && VERIFY_ONLY=1

verify() {
  ok=1
  for f in byte/SHA256ShortMsg.rsp byte/SHA256LongMsg.rsp \
           bit/SHA256ShortMsg.rsp  bit/SHA256LongMsg.rsp; do
    if [ -s "$VECTORS/$f" ]; then
      n=$(grep -c '^MD = ' "$VECTORS/$f" || true)
      printf '  ok      %-28s %s vectors\n' "$f" "$n"
    else
      printf '  MISSING %s\n' "$f"
      ok=0
    fi
  done
  [ "$ok" = 1 ]
}

if [ "$VERIFY_ONLY" = 1 ]; then
  hdr "NIST vectors present in $VECTORS"
  verify
  exit $?
fi

tmp=$(mktemp -d "${TMPDIR:-/tmp}/shavar-vectors.XXXXXX")
trap 'rm -rf "$tmp"' EXIT INT TERM

mkdir -p "$VECTORS/byte" "$VECTORS/bit"

hdr "fetching NIST CAVP SHAVS vectors"
for pair in "byte $BYTE_URL" "bit $BIT_URL"; do
  set -- $pair
  kind=$1; url=$2
  say "  $kind <- $url"
  code=$(curl -sS -L -o "$tmp/$kind.zip" -w '%{http_code}' "$url") || {
    err "download failed for $url"
    err "The vectors could not be fetched.  Nothing is invented in their place:"
    err "without them, obligation V5 of spec/SPEC.md 8 is simply unchecked."
    exit 1
  }
  if [ "$code" != 200 ]; then
    err "$url returned HTTP $code"
    err "NIST has moved these files before.  Search csrc.nist.gov for"
    err "'Secure Hash Algorithm Validation System SHAVS test vectors' and"
    err "update the URLs at the top of this script.  Do not substitute"
    err "expected digests from any other source without recording it here."
    exit 1
  fi
  unzip -o -j "$tmp/$kind.zip" \
      "*/SHA256ShortMsg.rsp" "*/SHA256LongMsg.rsp" -d "$VECTORS/$kind" >/dev/null
done

hdr "extracted"
verify
say ""
say "These files are committed to the repository on purpose; tests/nist.sh"
say "never touches the network."
