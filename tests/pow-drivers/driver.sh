#!/usr/bin/env bash
# PoW driver for sh/shavar.sh. See tests/pow.sh.
#
# Reads the vector file named on the command line and writes one
# `id <TAB> met|unmet|invalid` line per vector. Marshalling only: every
# decision comes from shavar_pow_check.
#
# Run under bash or zsh; tests/pow.sh runs it under both, because the shell
# implementation is one source file used by two shells and the two have
# genuinely different arithmetic and array semantics.
set -u

here=$(cd "$(dirname "$0")" && pwd)
SHAVAR_LIB=1 . "$here/../../sh/shavar.sh"

[ $# -eq 1 ] || { printf 'usage: driver.sh VECTORS.tsv\n' >&2; exit 2; }

while IFS=$'\t' read -r id dhex nbhex rest; do
  case "$id" in '#'* | '') continue ;; esac
  [ -n "${nbhex:-}" ] || continue
  nb=$(( 16#$nbhex ))
  if shavar_pow_check "$dhex" "$nb"; then
    verdict=met
  else
    case $? in
      1) verdict=unmet ;;
      *) verdict=invalid ;;
    esac
  fi
  printf '%s\t%s\n' "$id" "$verdict"
done < "$1"
