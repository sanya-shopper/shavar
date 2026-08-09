#!/bin/sh
#
# runhash.sh IMPL INPUTS OUT SHARD NSHARD
#
# Hash every INPUTS row whose 0-based position satisfies pos % NSHARD == SHARD,
# using implementation IMPL, and append `key <TAB> rc <TAB> digest` to OUT.
#
# INPUTS rows are `key <TAB> nbits <TAB> hex`, where hex is `-` for the empty
# message (the encoding fixed by spec/CLI.md).
#
# A digest of `-` means the implementation produced nothing usable; the rc
# column carries the exit status so the comparator can distinguish "wrong
# answer" from "refused to run" from "crashed".  Nothing is filtered here: bad
# output is recorded as bad output and reported later.

set -u
. "$(dirname "$0")/common.sh"

IMPL=$1; INPUTS=$2; OUT=$3; SHARD=$4; NSHARD=$5
: > "$OUT"
ERRLOG="$OUT.err"
: > "$ERRLOG"

pos=0
while IFS='	' read -r key nbits hex; do
  [ -n "${key:-}" ] || continue
  if [ $((pos % NSHARD)) -ne "$SHARD" ]; then pos=$((pos + 1)); continue; fi
  pos=$((pos + 1))

  out=$(impl_run "$IMPL" hash "$hex" "$nbits" 2>>"$ERRLOG")
  rc=$?
  # Keep only the first line and strip stray whitespace; the contract says a
  # single 64-hex line, and anything else must survive to the comparator as a
  # visible deviation rather than be normalised away.
  dig=$(printf '%s' "$out" | head -1 | tr -d ' \r\n\t')
  [ -n "$dig" ] || dig='-'
  printf '%s\t%s\t%s\n' "$key" "$rc" "$dig" >> "$OUT"
done < "$INPUTS"
