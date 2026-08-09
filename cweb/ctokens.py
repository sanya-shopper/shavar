#!/usr/bin/env python3
"""ctokens.py — normalise C source into a canonical token stream.

Used by test_cweb.sh to prove that the program ctangle extracts from
cweb/shavar-cweb.w is the *same program* as the hand-written sources in c/,
not merely one that passes the same tests.

The two cannot be compared as text: ctangle reformats freely, strips comments,
and interleaves `#line` directives.  So each side is first run through the C
preprocessor (`cc -E -P`, which expands macros and drops comments and line
markers) and then through this script, which reduces what is left to one
token per line.

String and character literals are kept verbatim, escape sequences included,
so a difference in a diagnostic message or in the usage text is a difference.
Everything else is split into identifiers, numbers, punctuators and operators
with all whitespace discarded, so a difference in formatting is not.

Reading from stdin, writing to stdout, one token per line, so that a failure
can be localised with plain `diff`.
"""

import re
import sys

# Order matters: the longest-matching alternative must come first within each
# group, and literals must be tried before the punctuation that can start them.
TOKEN = re.compile(
    r"""
      (?P<ws>\s+)
    | (?P<str>u8"|[uUL]?"(?:\\.|[^"\\\n])*")          # string literal
    | (?P<chr>[uUL]?'(?:\\.|[^'\\\n])*')              # character literal
    | (?P<num>\.?[0-9](?:[eEpP][+-]|[0-9a-zA-Z_.])*)  # pp-number
    | (?P<id>[A-Za-z_][A-Za-z_0-9]*)                  # identifier / keyword
    | (?P<punc>
          \.\.\.
        | (?:<<|>>|[-+*/%&|^!=<>]) =
        | \|\| | && | -> | \+\+ | -- | << | >>
        | [-+*/%&|^~!=<>?:;,.()\[\]{}]
        | \#\# | \#
      )
    """,
    re.VERBOSE,
)


def tokenize(text):
    pos, n = 0, len(text)
    while pos < n:
        m = TOKEN.match(text, pos)
        if m is None:
            line = text.count("\n", 0, pos) + 1
            raise SystemExit(
                "ctokens.py: cannot tokenize at line %d: %r"
                % (line, text[pos : pos + 40])
            )
        pos = m.end()
        kind = m.lastgroup
        if kind == "ws":
            continue
        # A string literal that starts u8" is only produced by the regex when
        # the full literal did not match; treat that as a hard error rather
        # than emitting a half token.
        if kind == "str" and m.group() in ('u8"', '"'):
            raise SystemExit("ctokens.py: unterminated string literal")
        yield m.group()


def main():
    out = sys.stdout.write
    for tok in tokenize(sys.stdin.read()):
        out(tok + "\n")


if __name__ == "__main__":
    main()
