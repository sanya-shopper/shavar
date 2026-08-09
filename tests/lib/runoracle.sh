#!/bin/sh
#
# runoracle.sh ORACLE INPUTS OUT
#
# Same output shape as runhash.sh, but driving one of the external SHA-256
# programs on this machine.  INPUTS must already be filtered to byte-aligned
# rows (nbits % 8 == 0): none of these tools can hash a partial byte, which is
# the central coverage limitation of external validation for this project.
#
# The hex payload is converted to raw bytes and delivered on stdin.  It is
# converted here rather than via a temporary file per input so that a run of a
# few thousand vectors does not create a few thousand files.

set -u
. "$(dirname "$0")/common.sh"

ORACLE=$1; INPUTS=$2; OUT=$3
: > "$OUT"

while IFS='	' read -r key nbits hex; do
  [ -n "${key:-}" ] || continue
  if [ "$hex" = '-' ] || [ "$nbits" = 0 ]; then
    dig=$(printf '' | oracle_hash "$ORACLE")
  else
    # `xxd -r -p` is the most portable hex->binary on macOS and Linux both.
    dig=$(printf '%s' "$hex" | xxd -r -p | oracle_hash "$ORACLE")
  fi
  rc=$?
  dig=$(printf '%s' "$dig" | tr -d ' \r\n\t')
  [ -n "$dig" ] || dig='-'
  printf '%s\t%s\t%s\n' "$key" "$rc" "$dig" >> "$OUT"
done < "$INPUTS"
