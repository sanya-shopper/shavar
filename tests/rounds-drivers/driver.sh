#!/usr/bin/env bash
# Rounds-contract driver for sh/shavar.sh. See tests/rounds.sh.
set -u
here=$(cd "$(dirname "$0")" && pwd)
SHAVAR_LIB=1 . "$here/../../sh/shavar.sh"
shavar__init
while IFS=$'\t' read -r r rest; do
  case "$r" in '#'* | '') continue ;; esac
  shavar_parse_hex 616263
  SHAVAR_H=("${SHAVAR_IV_IN[@]}")
  if shavar_hash_ex 24 "$r" 2>/dev/null; then
    printf '%s\taccepted\t' "$r"; shavar_print_digest
  else
    printf '%s\trejected\t-\n' "$r"
  fi
done < "$1"
