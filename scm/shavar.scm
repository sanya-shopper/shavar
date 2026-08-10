;;; shavar — SHA-256 written as a two-dimensional order-4 recurrence.
;;; R7RS-small Scheme.  See ../spec/SPEC.md (the algorithm) and ../spec/CLI.md
;;; (the command-line contract).  Both are normative; this file follows them.
;;;
;;; Run it as a program:
;;;
;;;     chibi-scheme scm/shavar.scm hash 616263 24
;;;     chibi-scheme scm/shavar.scm trace 616263 24 0
;;;     chibi-scheme scm/shavar.scm selftest
;;;
;;; ---------------------------------------------------------------------------
;;; READING THIS IF YOU DO NOT KNOW SCHEME
;;; ---------------------------------------------------------------------------
;;;
;;; This file is meant to be readable by someone fluent in C or Python who has
;;; never written Scheme.  Six conventions cover almost everything:
;;;
;;;   1. PARENTHESES ARE FUNCTION CALLS.  `(f x y)` is what C writes `f(x, y)`.
;;;      Operators are ordinary functions, so `(+ a b c)` is `a + b + c`.  The
;;;      parentheses are not decoration and are never optional: every one of
;;;      them is either a call or one of the handful of special forms below.
;;;      There is no operator precedence to remember because there are no
;;;      infix operators.
;;;
;;;   2. `(define (name arg ...) body ...)` defines a procedure; the value of
;;;      the last expression in the body is the return value.  There is no
;;;      `return` statement.  `(define name value)` defines a variable.
;;;
;;;   3. `(let ((x 1) (y 2)) body)` is a block with local bindings — C's
;;;      `{ int x = 1, y = 2; ... }`.  `let*` is the same but each binding can
;;;      see the previous ones, like ordinary sequential declarations.
;;;
;;;   4. NAMED LET is Scheme's loop.  `(let loop ((t 0)) ... (loop (+ t 1)))`
;;;      binds `loop` to a procedure whose parameters are the loop variables,
;;;      and calls it once with the initial values.  Each `(loop ...)` call is
;;;      the next iteration, with new values for the variables.  It reads like
;;;      recursion and runs like a `for` loop: see TAIL POSITION below.
;;;
;;;   5. TAIL POSITION.  An expression is in tail position if its value is
;;;      immediately the value of the enclosing procedure — nothing is left to
;;;      do after it returns.  R7RS *requires* implementations to execute a
;;;      call in tail position without growing the stack, so a self-call in
;;;      tail position is a jump, not a stack frame.  This is why the 64-round
;;;      loop below is written as recursion and still runs in constant space.
;;;      It is a language guarantee, not an optimisation you hope for.
;;;
;;;   6. NAMING.  A trailing `!` marks a procedure that mutates something
;;;      (`vector-set!`); a trailing `?` marks a predicate returning true or
;;;      false (`zero?`).  `#t` and `#f` are true and false; `'symbol` is a
;;;      quoted symbol, an interned name used here as a small enumeration.
;;;
;;; Two further constructs appear below and are explained where they are used:
;;; `syntax-rules` macros (see "THE RECURRENCE" and "THE ROUND FUNCTIONS") and
;;; multiple return values via `values` / `let-values` (see `sha256-round`).
;;;
;;; ---------------------------------------------------------------------------
;;; WHY THIS FILE IS SHAPED THE WAY IT IS
;;; ---------------------------------------------------------------------------
;;;
;;; SPEC.md §3 states the compression function as four lines:
;;;
;;;     T1[t] = E[t-4] + S1(E[t-1]) + Ch(E[t-1],E[t-2],E[t-3]) + K[t] + W[t]
;;;     T2[t] = S0(A[t-1]) + Maj(A[t-1],A[t-2],A[t-3])
;;;     E[t]  = A[t-4] + T1[t]
;;;     A[t]  = T1[t] + T2[t]
;;;
;;; Below, `define-recurrence` is a macro that lets those four lines be written
;;; out *verbatim* as the definition of the round.  That is the one thing this
;;; implementation is trying to show: in Scheme the specification and the
;;; program can be the same text, because a macro can supply the surrounding
;;; machinery (which variable is which lookback, how results are returned)
;;; without the algorithm having to mention it.

;; The entire dependency list.  Both are R7RS-small; nothing else is imported
;; unconditionally, and the one conditional import (section 1) is optional by
;; construction — the program runs, and is correct, without it.
(import (scheme base)             ; the language
        (scheme process-context)) ; command-line, exit

;;; ===========================================================================
;;; 1. THE BITWISE LAYER
;;; ===========================================================================
;;;
;;; R7RS-small has NO bitwise operations.  None: no and, or, xor, shift.  It
;;; has exact integers of unbounded size and the usual arithmetic on them, and
;;; that is all.  This is the single largest obstacle to writing SHA-256 in
;;; portable Scheme, so it is dealt with first and in the open.
;;;
;;; Two backends are provided and both are real:
;;;
;;;   * PORTABLE — bitwise operations reconstructed from `quotient`,
;;;     `remainder`, `+` and `*`.  Depends on nothing outside R7RS-small.
;;;   * NATIVE — the host's own bitwise primitives, picked up through
;;;     `cond-expand` when the host offers SRFI 151 or R7RS-large
;;;     `(scheme bitwise)`.  If it offers neither, the portable code is used.
;;;
;;; `selftest` runs every known-answer vector through BOTH backends, so the
;;; portable path is exercised on every run rather than being decorative.

;; `cond-expand` is compile-time conditional inclusion — C's `#if`, but keyed
;; on features the implementation declares rather than on macros you define.
;; `(library (srfi 151))` is a feature requirement that is satisfied exactly
;; when that library exists on this host, which is how a portable program asks
;; "do you have this?" without failing to load if the answer is no.
;;
;; This block must come before anything that uses these four names.  It binds
;; `bitwise-and`, `bitwise-ior`, `bitwise-xor` and `arithmetic-shift` either by
;; importing them or, in the fallback clause, by defining them in terms of the
;; portable procedures further down.  (Forward references are fine here: the
;; bodies are not evaluated until the procedures are called.)
(cond-expand
  ((library (srfi 151))
   (import (only (srfi 151)
                 bitwise-and bitwise-ior bitwise-xor arithmetic-shift)))
  ((library (scheme bitwise))
   (import (only (scheme bitwise)
                 bitwise-and bitwise-ior bitwise-xor arithmetic-shift)))
  (else
   (begin
     (define (bitwise-and x y) (portable-and x y))
     (define (bitwise-ior x y) (portable-ior x y))
     (define (bitwise-xor x y) (portable-xor x y))
     (define (arithmetic-shift x n) (portable-shift x n)))))

(cond-expand
  ((library (srfi 151))     (define host-bitwise-source "srfi 151"))
  ((library (scheme bitwise)) (define host-bitwise-source "scheme bitwise"))
  (else                     (define host-bitwise-source "none (portable)")))

;;; --- the portable reconstruction -------------------------------------------
;;;
;;; A bitwise binary operation is a function on single bits applied in
;;; parallel at all 32 positions.  Writing that down directly gives the
;;; definition below: strip the low bit off each operand with `remainder`,
;;; combine, shift down with `quotient`, and accumulate with a running place
;;; value.  No bit operations are used to implement bit operations.
;;;
;;; `bitwise-by-arithmetic` is a HIGHER-ORDER PROCEDURE: it takes a procedure
;;; and returns a new procedure.  `f` is the one-bit truth table, given as a
;;; function from two bits to a bit, and the result is the corresponding
;;; operation on whole non-negative integers.  In C this would be a function
;;; pointer plus a switch; in Scheme the closure captures `f` directly.
(define (bitwise-by-arithmetic f)
  (lambda (x y)
    (let loop ((x x) (y y) (place 1) (acc 0))
      (if (and (zero? x) (zero? y))
          acc
          (loop (quotient x 2)
                (quotient y 2)
                (* place 2)
                (+ acc (* place (f (remainder x 2) (remainder y 2)))))))))

;; The bit-at-a-time version above is the definition, but 32 iterations per
;; operation is wasteful.  `nibble-wise` takes such a definition and returns
;; the same function memoised on 4-bit groups: a 256-entry table indexed by
;; (high nibble * 16 + low nibble), so a 32-bit word takes eight iterations
;; instead of thirty-two.
;; Note that the table is built by *calling the bit-level definition*, so the
;; two agree by construction rather than by a second transcription.
(define (nibble-wise bit-level-op)
  (let ((table (make-vector 256 0)))
    (let fill ((i 0))
      (when (< i 256)
        (vector-set! table i (bit-level-op (quotient i 16) (remainder i 16)))
        (fill (+ i 1))))
    (lambda (x y)
      (let loop ((x x) (y y) (place 1) (acc 0))
        (if (and (zero? x) (zero? y))
            acc
            (loop (quotient x 16)
                  (quotient y 16)
                  (* place 16)
                  (+ acc (* place
                            (vector-ref table
                                        (+ (* 16 (remainder x 16))
                                           (remainder y 16)))))))))))

(define portable-and
  (nibble-wise (bitwise-by-arithmetic (lambda (p q) (* p q)))))
(define portable-ior
  (nibble-wise (bitwise-by-arithmetic (lambda (p q) (if (= 0 (+ p q)) 0 1)))))
(define portable-xor
  (nibble-wise (bitwise-by-arithmetic (lambda (p q) (remainder (+ p q) 2)))))

;; Shifting is just multiplication and division by powers of two.  Because
;; every value here is a non-negative exact integer, `quotient` is a *logical*
;; right shift with no sign-extension question to get wrong — one place where
;; the absence of fixed-width machine integers actually helps.
(define (portable-shift x n)
  (if (negative? n)
      (quotient x (expt 2 (- n)))
      (* x (expt 2 n))))

;;; --- backend selection ------------------------------------------------------
;;;
;;; These four are ordinary top-level variables holding procedures, not fixed
;;; definitions, so `use-bitwise-backend!` can swap the whole layer at run time
;;; and the rest of the file follows.  That is what lets `selftest` verify the
;;; portable path against the native one on identical inputs.
(define word-and   bitwise-and)
(define word-ior   bitwise-ior)
(define word-xor   bitwise-xor)
(define word-shift arithmetic-shift)

(define (use-bitwise-backend! which)
  (case which
    ((portable)
     (set! word-and portable-and)
     (set! word-ior portable-ior)
     (set! word-xor portable-xor)
     (set! word-shift portable-shift))
    ((native)
     (set! word-and bitwise-and)
     (set! word-ior bitwise-ior)
     (set! word-xor bitwise-xor)
     (set! word-shift arithmetic-shift))
    (else (error "unknown bitwise backend" which))))

;;; ===========================================================================
;;; 2. 32-BIT WORDS
;;; ===========================================================================
;;;
;;; A "word" here is an exact integer in [0, 2^32).  Scheme integers are
;;; unbounded, so nothing wraps by itself; every operation that can overflow
;;; ends in an explicit reduction.  Making the reduction explicit is not a
;;; nuisance — SPEC.md §7.1 is about exactly where the carries live, and in
;;; this file every place a carry can happen is a visible call to `w+`.

(define word-size    32)
(define word-modulus 4294967296)   ; 2^32
(define word-mask    4294967295)   ; 2^32 - 1

(define (u32 x) (modulo x word-modulus))

;; Addition modulo 2^32.  Variadic, so the five-term sum of SPEC.md §3 is one
;; call.  `(define (w+ . words) ...)` collects all arguments into a list, and
;; `apply` spreads that list back out as arguments to `+`.
(define (w+ . words) (u32 (apply + words)))

;; Exclusive or, variadic, folded left with a named let.
(define (wxor . words)
  (let loop ((acc 0) (rest words))
    (if (null? rest)
        acc
        (loop (word-xor acc (car rest)) (cdr rest)))))

(define (wand x y) (word-and x y))

;; Bitwise complement on 32 bits needs no bit operation at all: since every
;; bit of `word-mask` is 1, flipping x is subtracting it.  (Correct only
;; because x is guaranteed to be in range, which is the invariant `u32`
;; maintains everywhere.)
(define (wnot x) (- word-mask x))

;; Logical right shift, zero-filled.
(define (shr x n) (word-shift x (- n)))

;; Circular right rotation: the bits shifted off the bottom come back at the
;; top.  The two halves occupy disjoint bit positions, so `word-ior` here could
;; equally be `+`; it is written as a disjunction because that is the usual
;; definition, and because doing so keeps `word-ior` exercised in both backends.
(define (rotr x n)
  (word-ior (word-shift x (- n))
            (u32 (word-shift x (- word-size n)))))

;;; ===========================================================================
;;; 3. THE ROUND FUNCTIONS  (SPEC.md §1.1)
;;; ===========================================================================
;;;
;;; `Ch` and `Maj` are the two nonlinear functions; both act one bit position
;;; at a time.  They are kept as separate named procedures, rather than being
;;; folded into the round expression, because SPEC.md §7.1 turns on which
;;; pieces are GF(2)-linear and research code needs to replace them one at a
;;; time.
;;;
;;; Scheme is case sensitive, so `Sigma0` (on the state) and `sigma0` (on the
;;; message schedule) are genuinely different names, matching the Σ/σ of the
;;; specification without needing to invent new ones.

(define (ch x y z)  (wxor (wand x y) (wand (wnot x) z)))
(define (maj x y z) (wxor (wand x y) (wand x z) (wand y z)))

;;; The four sigma functions are each "xor together some rotations and shifts
;;; of the argument", differing only in a list of amounts.  Writing four nearly
;;; identical procedure bodies invites a transcription error in one of the
;;; twelve constants, which is precisely the failure SPEC.md §9 warns about.
;;; So instead we teach the language the shape.
;;;
;;; A `syntax-rules` macro is a set of PATTERN / TEMPLATE pairs.  The compiler
;;; matches each use of the macro against the patterns; `...` in a pattern
;;; means "zero or more of the preceding form", and the same `...` in the
;;; template means "expand once per match".  Below, the pattern
;;;
;;;     (_ name (op amount) ...)
;;;
;;; matches the macro name (`_`), then an identifier, then any number of
;;; two-element groups, and binds `op` and `amount` to those two sequences.
;;; The template rebuilds them as calls.  So
;;;
;;;     (define-bit-mixer Sigma0 (rotr 2) (rotr 13) (rotr 22))
;;;
;;; expands to exactly
;;;
;;;     (define (Sigma0 x) (wxor (rotr x 2) (rotr x 13) (rotr x 22)))
;;;
;;; This is a syntactic transformation, not a function: it happens before the
;;; program runs, and the result is the same code you would have typed.  Note
;;; also that `x` is introduced by the macro.  `syntax-rules` is HYGIENIC,
;;; meaning that identifier cannot capture or be captured by any `x` at the
;;; use site — unlike a C preprocessor macro, where that is a real hazard.
(define-syntax define-bit-mixer
  (syntax-rules ()
    ((_ name (op amount) ...)
     (define (name x) (wxor (op x amount) ...)))))

;; Compare directly against SPEC.md §1.1; the amounts are all that is here.
(define-bit-mixer Sigma0 (rotr  2) (rotr 13) (rotr 22))
(define-bit-mixer Sigma1 (rotr  6) (rotr 11) (rotr 25))
(define-bit-mixer sigma0 (rotr  7) (rotr 18) (shr   3))
(define-bit-mixer sigma1 (rotr 17) (rotr 19) (shr  10))

;;; ===========================================================================
;;; 4. CONSTANTS  (SPEC.md §9)
;;; ===========================================================================

(define sha256-iv
  (vector #x6a09e667 #xbb67ae85 #x3c6ef372 #xa54ff53a
          #x510e527f #x9b05688c #x1f83d9ab #x5be0cd19))

(define sha256-k
  (vector
   #x428a2f98 #x71374491 #xb5c0fbcf #xe9b5dba5 #x3956c25b #x59f111f1
   #x923f82a4 #xab1c5ed5 #xd807aa98 #x12835b01 #x243185be #x550c7dc3
   #x72be5d74 #x80deb1fe #x9bdc06a7 #xc19bf174 #xe49b69c1 #xefbe4786
   #x0fc19dc6 #x240ca1cc #x2de92c6f #x4a7484aa #x5cb0a9dc #x76f988da
   #x983e5152 #xa831c66d #xb00327c8 #xbf597fc7 #xc6e00bf3 #xd5a79147
   #x06ca6351 #x14292967 #x27b70a85 #x2e1b2138 #x4d2c6dfc #x53380d13
   #x650a7354 #x766a0abb #x81c2c92e #x92722c85 #xa2bfe8a1 #xa81a664b
   #xc24b8b70 #xc76c51a3 #xd192e819 #xd6990624 #xf40e3585 #x106aa070
   #x19a4c116 #x1e376c08 #x2748774c #x34b0bcb5 #x391c0cb3 #x4ed8aa4a
   #x5b9cca4f #x682e6ff3 #x748f82ee #x78a5636f #x84c87814 #x8cc70208
   #x90befffa #xa4506ceb #xbef9a3f7 #xc67178f2))

;;; SPEC.md §9 asks that the constants be recomputed from the primes rather
;;; than trusted as transcribed, and Scheme can do that with no library at all:
;;; its integers are exact and unbounded, so the irrational roots can be taken
;;; in fixed point with no floating-point rounding anywhere near the answer.
;;; `selftest` checks the two tables above against these derivations.

;; floor(n^(1/k)) for exact non-negative n, by Newton's method on integers.
;; Starting above the root and stepping down, the first non-decrease is the
;; floor.  All arithmetic is exact, so there is no epsilon to tune.
(define (integer-root n k)
  (if (< n 2)
      n
      (let loop ((x n))
        (let ((next (quotient (+ (* (- k 1) x)
                                 (quotient n (expt x (- k 1))))
                              k)))
          (if (< next x) (loop next) x)))))

;; The first 32 bits of the fractional part of p^(1/k), as an integer.
;; floor(2^32 * p^(1/k)) = floor((p * 2^(32k))^(1/k)); subtracting
;; 2^32 * floor(p^(1/k)) removes the integer part and leaves the fraction.
(define (root-fraction-word p k)
  (- (integer-root (* p (expt 2 (* word-size k))) k)
     (* word-modulus (integer-root p k))))

(define (prime? n)
  (and (> n 1)
       (let loop ((d 2))
         (cond ((> (* d d) n) #t)
               ((zero? (remainder n d)) #f)
               (else (loop (+ d 1)))))))

(define (first-primes count)
  (let loop ((candidate 2) (found '()) (n 0))
    (cond ((= n count) (reverse found))
          ((prime? candidate) (loop (+ candidate 1) (cons candidate found) (+ n 1)))
          (else (loop (+ candidate 1) found n)))))

;; `map` applies a procedure across a list; `list->vector` converts.  Reading
;; this as one expression is the point: "the IV is the square-root fractions of
;; the first eight primes".
(define (derive-iv)
  (list->vector (map (lambda (p) (root-fraction-word p 2)) (first-primes 8))))

(define (derive-k)
  (list->vector (map (lambda (p) (root-fraction-word p 3)) (first-primes 64))))

;;; ===========================================================================
;;; 5. THE MESSAGE SCHEDULE  (SPEC.md §4)
;;; ===========================================================================
;;;
;;; An order-16 recurrence:  W[t] = M[t] for t < 16, and thereafter
;;; W[t] = sigma1(W[t-2]) + W[t-7] + sigma0(W[t-15]) + W[t-16].

;; Read four bytes big-endian.  Written with multiplication rather than shifts
;; so it says what it means and cannot depend on host endianness.
(define (bytevector-be32-ref bv i)
  (+ (* 16777216 (bytevector-u8-ref bv i))
     (*    65536 (bytevector-u8-ref bv (+ i 1)))
     (*      256 (bytevector-u8-ref bv (+ i 2)))
     (bytevector-u8-ref bv (+ i 3))))

(define (message-schedule block)
  (let ((w (make-vector 64 0)))
    (let load ((t 0))
      (when (< t 16)
        (vector-set! w t (bytevector-be32-ref block (* 4 t)))
        (load (+ t 1))))
    (let extend ((t 16))
      (when (< t 64)
        (vector-set! w t
                     (w+ (sigma1 (vector-ref w (- t 2)))
                         (vector-ref w (- t 7))
                         (sigma0 (vector-ref w (- t 15)))
                         (vector-ref w (- t 16))))
        (extend (+ t 1))))
    w))

;;; ===========================================================================
;;; 6. THE RECURRENCE  (SPEC.md §3)
;;; ===========================================================================
;;;
;;; This is the centre of the file.
;;;
;;; `define-recurrence` is a macro whose whole purpose is to let the round be
;;; written as the four lines of SPEC.md §3 and nothing else.  It supplies:
;;;
;;;   * the parameter list, so the eight lookback values arrive under the names
;;;     the specification uses;
;;;   * the sequencing, so T1 and T2 are computed before they are used;
;;;   * the return convention, so the caller receives A[t], E[t], T1[t], T2[t].
;;;
;;; `(syntax-rules (=) ...)` lists `=` as a LITERAL: it must appear in the use,
;;; and it matches itself rather than binding a pattern variable.  That is what
;;; makes `(T1 = expr)` legal syntax here and lets the four lines keep their
;;; equation shape.  Everything else in the pattern is a pattern variable, so
;;; the names `A_t-1`, `E_t-4`, `T1`, `K_t` and so on come from the USE below,
;;; not from this definition — the macro does not know or care what they are
;;; called, only where they sit.  (`A_t-1` is one identifier, read as A[t-1];
;;; Scheme identifiers may contain `-` and `_` freely.)
;;;
;;; `values` returns several results at once, and the caller destructures them
;;; with `let-values` (used in `compress` below).  It is not a tuple: there is
;;; no object to name or take apart afterwards, and the caller must accept
;;; exactly as many results as were sent — four, here.
(define-syntax define-recurrence
  (syntax-rules (=)
    ((_ (name A_t-1 A_t-2 A_t-3 A_t-4
              E_t-1 E_t-2 E_t-3 E_t-4
              K_t W_t)
        (T1 = T1-expr)
        (T2 = T2-expr)
        (E_t = E-expr)
        (A_t = A-expr))
     (define (name A_t-1 A_t-2 A_t-3 A_t-4
                   E_t-1 E_t-2 E_t-3 E_t-4
                   K_t W_t)
       (let* ((T1 T1-expr)
              (T2 T2-expr)
              (E_t E-expr)
              (A_t A-expr))
         (values A_t E_t T1 T2))))))

;;; One round of SHA-256.  Below the parameter list, the four lines are
;;; SPEC.md §3 transcribed with `+` spelled `w+`; there is nothing else to
;;; check them against and nothing else in them.
(define-recurrence
  (sha256-round A_t-1 A_t-2 A_t-3 A_t-4
                E_t-1 E_t-2 E_t-3 E_t-4
                K_t W_t)
  (T1  = (w+ E_t-4 (Sigma1 E_t-1) (ch E_t-1 E_t-2 E_t-3) K_t W_t))
  (T2  = (w+ (Sigma0 A_t-1) (maj A_t-1 A_t-2 A_t-3)))
  (E_t = (w+ A_t-4 T1))
  (A_t = (w+ T1 T2)))

;;; ===========================================================================
;;; 7. COMPRESSION
;;; ===========================================================================
;;;
;;; A trace is the complete interior of one block's compression, as required by
;;; SPEC.md §6.  `define-record-type` (R7RS-small) declares a new disjoint type
;;; together with its constructor, its type predicate, and one accessor per
;;; field — roughly a C struct plus its getters, in one form.
;;;
;;; The A and E tracks are vectors of length 68 holding t = -4 .. 63 at index
;;; t + 4.  The offset is confined to the two accessors `trace-a` / `trace-e`
;;; so that no other code has to remember it.
(define-record-type <trace>
  (make-trace hin hout w a-track e-track t1 t2 rounds)
  trace?
  (hin      trace-hin)        ; vector of 8, chaining value entering the block
  (hout     trace-hout)       ; vector of 8, chaining value leaving it
  (w        trace-w)          ; vector of 64
  (a-track  trace-a-track)    ; vector of 68, index t+4
  (e-track  trace-e-track)
  (t1       trace-t1)         ; vector of 64
  (t2       trace-t2)
  (rounds   trace-rounds))

(define (trace-a tr t) (vector-ref (trace-a-track tr) (+ t 4)))
(define (trace-e tr t) (vector-ref (trace-e-track tr) (+ t 4)))

;;; Compress one 64-byte block into the chaining value `h` (a vector of eight
;;; words), running `rounds` rounds.  Returns a trace; the outgoing chaining
;;; value is `(trace-hout ...)`.  Neither `h` nor `block` is modified.
;;;
;;; `h` is a caller-supplied parameter and `rounds` may be less than 64: these
;;; are the free-start and reduced-round handles SPEC.md §6 requires, and they
;;; are the primitive on which everything else in this file is built rather
;;; than an extra bolted on beside it.
(define (compress h block rounds)
  ;; SPEC.md 6.1.  Outside 0..64 there is no such function, so this is an
  ;; error rather than a request to be interpreted.  Without the check the
  ;; round loop indexes past the end of the K vector and the whole program
  ;; dies with an implementation backtrace -- which tells the caller that
  ;; something is wrong but not what, and a crash inside a library is not a
  ;; diagnosis.  The CLI checked the range in `parse-rounds`; nothing checked
  ;; it for a caller that loaded this file as a library.
  (if (or (not (integer? rounds)) (< rounds 0) (> rounds 64))
      (shavar-error "rounds must be 0..64" rounds))
  (let ((w  (message-schedule block))
        (a  (make-vector 68 0))
        (e  (make-vector 68 0))
        (t1 (make-vector 64 0))
        (t2 (make-vector 64 0)))
    ;; Internal definitions; in Scheme these must all precede the expressions
    ;; of the body.  A@ and E@ index by the spec's t, hiding the +4 offset.
    (define (A@ t) (vector-ref a (+ t 4)))
    (define (E@ t) (vector-ref e (+ t 4)))

    ;; Seed the lookback window from the incoming chaining value:
    ;; A[-1]=H0 A[-2]=H1 A[-3]=H2 A[-4]=H3, E[-1]=H4 ... E[-4]=H7.
    (let seed ((i 0))
      (when (< i 4)
        (vector-set! a (- 3 i) (vector-ref h i))
        (vector-set! e (- 3 i) (vector-ref h (+ i 4)))
        (seed (+ i 1))))

    ;; The round loop.  `(round-loop (+ t 1))` is in tail position, so this is
    ;; a jump: 64 iterations, constant stack.  Compare the eight-register form,
    ;; which needs six copy assignments per round; here the "shift register" is
    ;; just reading four positions back in the history, so there is nothing to
    ;; permute and nothing to get wrong.
    (let round-loop ((t 0))
      (when (< t rounds)
        (let-values (((A_t E_t T1_t T2_t)
                      (sha256-round (A@ (- t 1)) (A@ (- t 2))
                                    (A@ (- t 3)) (A@ (- t 4))
                                    (E@ (- t 1)) (E@ (- t 2))
                                    (E@ (- t 3)) (E@ (- t 4))
                                    (vector-ref sha256-k t)
                                    (vector-ref w t))))
          (vector-set! a (+ t 4) A_t)
          (vector-set! e (+ t 4) E_t)
          (vector-set! t1 t T1_t)
          (vector-set! t2 t T2_t))
        (round-loop (+ t 1))))

    ;; H[i] += A[rounds-1-i] for i<4, H[4+i] += E[rounds-1-i].  At full 64
    ;; rounds this is SPEC.md §3's feed-forward verbatim; for reduced rounds it
    ;; is the same window one step past the last round computed, which is what
    ;; the eight-register form would have in a..h at that point.  Because the
    ;; seeds live at t = -4 .. -1, this stays well defined down to rounds = 0.
    (let ((hout (make-vector 8 0)))
      (let feed ((i 0))
        (when (< i 4)
          (vector-set! hout i
                       (w+ (vector-ref h i) (A@ (- rounds 1 i))))
          (vector-set! hout (+ i 4)
                       (w+ (vector-ref h (+ i 4)) (E@ (- rounds 1 i))))
          (feed (+ i 1))))
      (make-trace h hout w a e t1 t2 rounds))))

;;; ===========================================================================
;;; 8. PADDING FOR ARBITRARY BIT LENGTH  (SPEC.md §5)
;;; ===========================================================================
;;;
;;; The message is a bytevector of ceil(L/8) bytes plus the bit count L.  When
;;; L is not a multiple of 8 the final byte carries its significant bits in the
;;; HIGH-order positions and its low-order bits must be zero; a nonzero low bit
;;; is rejected, never masked (SPEC.md §5.1).
;;;
;;; The padded stream is never materialised.  `padded-block` computes block
;;; number `idx` on demand, which is what makes `trace <hex> <nbits> <block>`
;;; cheap and keeps memory flat for long messages.

(define max-message-bits (expt 2 64))   ; the standard's bound: L < 2^64

;; Raise an error carrying `message`.  `error` creates and raises an "error
;; object"; the CLI (section 12) catches it with `guard` and turns it into
;; exit code 2.  Errors are values here, not a separate control-flow mechanism.
(define (shavar-error message . irritants)
  (apply error message irritants))

(define (validate-message msg nbits)
  (let ((need (quotient (+ nbits 7) 8))
        (have (bytevector-length msg)))
    (cond
     ((>= nbits max-message-bits)
      (shavar-error "message length exceeds the 2^64-bit bound" nbits))
     ((not (= need have))
      (shavar-error "byte count does not match bit count" have need))
     ((and (positive? (remainder nbits 8))
           (not (zero? (remainder (bytevector-u8-ref msg (- have 1))
                                  (expt 2 (- 8 (remainder nbits 8)))))))
      (shavar-error
       "nonzero trailing bits in final byte (see SPEC.md 5.1)"
       (bytevector-u8-ref msg (- have 1)) nbits))
     (else #t))))

;; L + 1 + k + 64 == 0 (mod 512) with k minimal, so the padded length in
;; blocks is floor((L + 64) / 512) + 1.
(define (padded-block-count nbits)
  (+ 1 (quotient (+ nbits 64) 512)))

;; Byte `p` of block `idx` of the padded message.  Four regions, in order of
;; increasing byte index: whole message bytes; the one byte that carries the
;; final partial byte together with the appended 1 bit; zeros; the 64-bit
;; big-endian length.  They cannot overlap, because L < 512*blocks - 64 forces
;; floor(L/8) < total - 8.
(define (padded-block msg nbits idx)
  (let* ((total   (* 64 (padded-block-count nbits)))
         (q       (quotient nbits 8))     ; index of the byte holding the 1 bit
         (r       (remainder nbits 8))    ; significant bits already in it
         (block   (make-bytevector 64 0)))
    (let fill ((p 0))
      (when (< p 64)
        (let ((g (+ (* idx 64) p)))       ; byte index in the padded stream
          (bytevector-u8-set!
           block p
           (cond
            ((< g q) (bytevector-u8-ref msg g))
            ((= g q)
             ;; the appended 1 bit sits at bit 7-r of this byte, i.e. adds
             ;; 128 / 2^r; the low bits are known zero, so + is exact here
             (+ (if (zero? r) 0 (bytevector-u8-ref msg q))
                (quotient 128 (expt 2 r))))
            ((>= g (- total 8))
             ;; big-endian byte (total-1-g) of the 64-bit length
             (remainder (quotient nbits (expt 256 (- total 1 g))) 256))
            (else 0))))
        (fill (+ p 1))))
    block))

;;; ===========================================================================
;;; 9. HASHING
;;; ===========================================================================
;;;
;;; Merkle-Damgard: fold `compress` over the padded blocks, starting from the
;;; chaining value.  The named let below is the fold, and `h` is the
;;; accumulator; each iteration produces a fresh vector rather than mutating,
;;; so the intermediate chaining values are all still valid objects if a caller
;;; wants to keep them.

;; Digest `nbits` bits of `msg` from a caller-supplied IV and round count.
;; Returns a vector of eight words.
(define (shavar-digest/iv msg nbits iv rounds)
  (validate-message msg nbits)
  (let ((blocks (padded-block-count nbits)))
    (let fold ((i 0) (h iv))
      (if (= i blocks)
          h
          (fold (+ i 1)
                (trace-hout (compress h (padded-block msg nbits i) rounds)))))))

;; The FIPS 180-4 function: standard IV, 64 rounds.
(define (shavar-digest msg nbits)
  (shavar-digest/iv msg nbits sha256-iv 64))

;; The trace of one block, with the chaining value that block actually sees.
(define (shavar-block-trace msg nbits idx iv rounds)
  (validate-message msg nbits)
  (let fold ((i 0) (h iv))
    (if (= i idx)
        (compress h (padded-block msg nbits i) rounds)
        (fold (+ i 1)
              (trace-hout (compress h (padded-block msg nbits i) rounds))))))

;;; ===========================================================================
;;; 10. PROOF OF WORK  (SPEC.md §10)
;;; ===========================================================================
;;;
;;; The argument called `nbits` in this section is Bitcoin's compact *target*
;;; encoding and has nothing to do with the message bit length called `nbits`
;;; everywhere else in this file.  The collision of names is inherited from
;;; both conventions rather than chosen here.
;;;
;;; Scheme has exact arbitrary-precision integers and could do this by
;;; shifting one number, but the target is built as 32 bytes the same way the
;;; six sibling implementations must, none of which has a bignum available.
;;; Seven versions agreeing is worth more when they agree for the same
;;; reasons.  The arithmetic below uses `quotient` and `remainder` rather than
;;; the bitwise layer of section 1, so it is independent of which backend that
;;; layer selected.

;; Decode a compact `nbits` target into a 32-byte BIG-endian bytevector: index
;; 0 is the most significant byte.  Raises an error if the encoding is
;; negative, overflows 256 bits, or denotes zero.
(define (pow-target nbits)
  (let* ((exponent (quotient nbits 16777216))       ; the high byte
         (mantissa (remainder nbits 8388608))       ; the low 23 bits
         ;; Bit 23 is the sign bit: the low bit of everything above the
         ;; mantissa.  A target is an unsigned magnitude, so a set sign bit is
         ;; an error rather than something to mask away.  Guarded on a nonzero
         ;; mantissa to match Bitcoin's SetCompact exactly.
         (negative (and (not (zero? mantissa))
                        (odd? (quotient nbits 8388608)))))
    (if negative
        (shavar-error "nBits is negative" nbits))
    (if (and (not (zero? mantissa))
             (or (> exponent 34)
                 (and (> mantissa 255)   (> exponent 33))
                 (and (> mantissa 65535) (> exponent 32))))
        (shavar-error "nBits overflows 256 bits" nbits))

    (let ((t (make-bytevector 32 0)))
      ;; `place!` writes one byte at a big-endian index, ignoring an index
      ;; that has fallen off the top.  The overflow test above guarantees that
      ;; only zero bytes can do so.
      (let ((place! (lambda (idx v)
                      (if (>= idx 0) (bytevector-u8-set! t idx v)))))
        (if (<= exponent 3)
            ;; The mantissa shifts down and may vanish entirely.
            (let ((v (quotient mantissa (expt 256 (- 3 exponent)))))
              (place! 31 (remainder v 256))
              (place! 30 (remainder (quotient v 256) 256))
              (place! 29 (quotient v 65536)))
            ;; `shift` is the byte offset of the mantissa's low byte from the
            ;; least significant end, so in a big-endian array it lands at
            ;; index 31 - shift.
            (let ((shift (- exponent 3)))
              (place! (- 31 shift) (remainder mantissa 256))
              (place! (- 30 shift) (remainder (quotient mantissa 256) 256))
              (place! (- 29 shift) (quotient mantissa 65536)))))

      ;; A zero target is unsatisfiable, so it is a malformed request rather
      ;; than a verdict of "no" against every possible digest.
      (let loop ((i 0))
        (cond ((= i 32) (shavar-error "nBits denotes a zero target" nbits))
              ((not (zero? (bytevector-u8-ref t i))) t)
              (else (loop (+ i 1))))))))

;; Does `digest` — 32 bytes in EMISSION order, the order the hash function
;; produced them — meet the target encoded by `nbits`?  Returns #t or #f, and
;; raises an error if `nbits` is invalid.
;;
;; THE BYTE ORDER, which is the only thing here that is easy to get wrong: the
;; digest is read LITTLE-endian.  Byte 0, the first byte the hash function
;; emitted, is the LEAST significant byte of the 256-bit value and byte 31 is
;; the MOST significant.  That is the reverse of the order the bytes are
;; written in, and it is why a Bitcoin block hash is displayed reversed
;; relative to the digest actually computed.  See SPEC.md §10.1.
;;
;; The comparison is "at most", not "strictly less".
(define (pow-check digest nbits)
  (if (not (= (bytevector-length digest) 32))
      (shavar-error "digest must be 32 bytes" (bytevector-length digest)))
  (let ((t (pow-target nbits)))
    ;; Both values walked most significant byte first.  `t` is already in that
    ;; order; the digest is not, so it is indexed backwards.  `(- 31 i)` is the
    ;; whole convention — using `i` there is the classic byte-order bug, and it
    ;; is silent.
    (let loop ((i 0))
      (if (= i 32)
          #t                            ; every byte equal: value = target
          (let ((a (bytevector-u8-ref digest (- 31 i)))
                (b (bytevector-u8-ref t i)))
            (cond ((< a b) #t)
                  ((> a b) #f)
                  (else (loop (+ i 1)))))))))

;;; ===========================================================================
;;; 11. HEX
;;; ===========================================================================

(define hex-alphabet "0123456789abcdef")

;; Exactly 8 lowercase hex digits, zero padded.  Built by hand rather than with
;; `number->string`, whose letter case R7RS leaves unspecified — and CLI.md
;; makes the case part of the contract.
(define (word->hex w)
  (let ((s (make-string 8 #\0)))
    (let loop ((i 7) (v w))
      (if (< i 0)
          s
          (begin
            (string-set! s i (string-ref hex-alphabet (remainder v 16)))
            (loop (- i 1) (quotient v 16)))))))

(define (digest->hex h)
  (apply string-append (map word->hex (vector->list h))))

(define (hex-digit-value ch)
  (let ((c (char->integer ch)))
    (cond ((and (>= c 48) (<= c  57)) (- c 48))   ; 0-9
          ((and (>= c 97) (<= c 102)) (- c 87))   ; a-f
          ((and (>= c 65) (<= c  70)) (- c 55))   ; A-F
          (else #f))))

;; Returns a bytevector, or #f if the string is not valid hex.  The single
;; character "-" denotes the empty message (CLI.md).
(define (hex->bytevector s)
  (cond
   ((string=? s "-") (bytevector))
   ((odd? (string-length s)) #f)
   (else
    (let* ((n  (quotient (string-length s) 2))
           (bv (make-bytevector n 0)))
      (let loop ((i 0))
        (if (= i n)
            bv
            (let ((hi (hex-digit-value (string-ref s (* 2 i))))
                  (lo (hex-digit-value (string-ref s (+ 1 (* 2 i))))))
              (and hi lo
                   (begin
                     (bytevector-u8-set! bv i (+ (* 16 hi) lo))
                     (loop (+ i 1)))))))))))

;;; ===========================================================================
;;; 12. SELF-TEST VECTORS
;;; ===========================================================================
;;;
;;; Each case is a list (label expected thunk).  The thunk returns a string;
;;; the case passes when it equals `expected`.  Framing non-digest checks the
;;; same way keeps the FAIL output of CLI.md uniform.

;; A free-start (chosen-IV) chaining value, used to exercise the handle that
;; SPEC.md §6 requires and that a plain hashing API cannot reach.
(define free-start-iv
  (vector #x01234567 #x89abcdef #xfedcba98 #x76543210
          #x0f1e2d3c #x4b5a6978 #x8796a5b4 #xc3d2e1f0))

;; (hex nbits rounds iv expected)
(define known-answers
  (list
   ;; --- byte-aligned, FIPS IV, full rounds ---------------------------------
   (list "-" 0 64 'fips
         "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
   (list "61" 8 64 'fips
         "ca978112ca1bbdcafac231b39a23dc4da786eff8147c4e72b9807785afee48bb")
   (list "00" 8 64 'fips
         "6e340b9cffb37a989ca544e6bb780a2c78901d3fb33738768511a30617afa01d")
   (list "616263" 24 64 'fips
         "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
   ;; 448 bits: the last message that still fits in a single padded block
   (list (string-append "6162636462636465636465666465666765666768666768696768"
                        "696a68696a6b696a6b6c6a6b6c6d6b6c6d6e6c6d6e6f6d6e6f70"
                        "6e6f7071")
         448 64 'fips
         "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1")
   ;; 896 bits: two padded blocks
   (list (string-append "61626364656667686263646566676869636465666768696a6465"
                        "666768696a6b65666768696a6b6c666768696a6b6c6d6768696a"
                        "6b6c6d6e68696a6b6c6d6e6f696a6b6c6d6e6f706a6b6c6d6e6f"
                        "70716b6c6d6e6f7071726c6d6e6f707172736d6e6f7071727374"
                        "6e6f707172737475")
         896 64 'fips
         "cf5b16a778af8380036ce59e7b0492370b249b11e8f07a51afac45037afee9d1")
   ;; --- sub-byte and non-multiple-of-8 bit lengths (SPEC.md 5) -------------
   (list "80" 1 64 'fips
         "b9debf7d52f36e6468a54817c1fa071166c3a63d384850e1575b42f702dc5aa1")
   (list "00" 1 64 'fips
         "bd4f9e98beb68c6ead3243b1b4c7fed75fa4feaab1f84795cbd8a98676a2a375")
   (list "50" 4 64 'fips
         "f1541deb68d134eba99f82cfd87e2ab31d33af4b6de0086a9bed15c2ec69cccb")
   ;; SPEC.md 5.2's worked example: the five bits 10110
   (list "b0" 5 64 'fips
         "82c9ef980dfdf26f0cb97f59d34a60dc39c82e489da9ca2132681fe0aa14270a")
   ;; the same five leading bits with a different (still legal) tail byte
   (list "b8" 5 64 'fips
         "9103bf6cd9f1134d81807ade91d54d9888b1a3df1f947f735ce00220dca5261c")
   (list "68" 6 64 'fips
         "dcddada4bfee21e9d6f6ad3253939608d1c3f76da31854b41f81a972107fe745")
   (list "fe" 7 64 'fips
         "7bbca3be22fe9d6a58cb656c5a3ab902aac8fba77c7b464eb94c2c50eba0e1d1")
   (list "ff80" 9 64 'fips
         "6a9d7293537d56731cf8c72552b48833cfe3111bff4f3a7b90657431fd87931e")
   ;; block-boundary bit lengths: 447 fits, 448 spills into a second block
   (list (string-append "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
                        "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
                        "aaaaaaaa")
         447 64 'fips
         "442050a57b1363bce7f93ffdd39e1b1b74149360852f7023f8a505d9af36862a")
   (list (string-append "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
                        "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
                        "aaaaaaaa")
         448 64 'fips
         "d464bb04abbc80a2254cd4ad0f3356f1b70b5b6390085b193edcd291f065b01e")
   (list (string-append "ffffffffffffffffffffffffffffffffffffffffffffffffffff"
                        "ffffffffffffffffffffffffffffffffffffffffffffffffffff"
                        "fffffffffffffffffffffffe")
         511 64 'fips
         "72c10a554047e0b01956ca3c5c2f4e968b78ff427e3c904774d51c1045447a40")
   (list (string-append "ffffffffffffffffffffffffffffffffffffffffffffffffffff"
                        "ffffffffffffffffffffffffffffffffffffffffffffffffffff"
                        "ffffffffffffffffffffffff")
         512 64 'fips
         "8667e718294e9e0df1d30600ba3eeb201f764aad2dad72748643e4a285e1d1f7")
   (list (string-append "ffffffffffffffffffffffffffffffffffffffffffffffffffff"
                        "ffffffffffffffffffffffffffffffffffffffffffffffffffff"
                        "ffffffffffffffffffffffff80")
         513 64 'fips
         "dcd50b6c8a8b9329b91930476c54d6e702ff6c23ef998cb2c3ad6fe81337b77c")
   ;; --- reduced rounds (SPEC.md 6): not SHA-256, for cryptanalysis ---------
   (list "616263" 24 1 'fips
         "c774d234257194ecf7d6a1f7e1bee8ac4b3898a1ec13bb0bba8942377b64a6c4")
   (list "616263" 24 16 'fips
         "1b0409f57bcc0e6315a1de882ce11eca5867604ca6985a9893de22897a384f31")
   (list "616263" 24 32 'fips
         "ddbd225ca600d8a7dc74fea2db8478030b6763919c0f13c6cd6b6de2bcf370d0")
   ;; --- free start: a caller-supplied chaining value ------------------------
   (list "616263" 24 64 'free
         "4dc4541421359ca8177513ca4145df34bf18c4a02122d45cb10d5b3dcf8a1237")
   (list "616263" 24 24 'free
         "eefc30313b76103de7f972a6996076bff538ae1c273624acbcc57b60cdb504e4")))

;; Field accessors for a known-answer entry.  `list-ref` indexes a list;
;; naming the positions keeps the rest of this section readable.  (Scheme's
;; `caddr`/`cadddr` would do too, but they live in `(scheme cxr)` and this file
;; deliberately imports nothing but `base`, `write` and `process-context`.)
(define (kat-hex      kat) (list-ref kat 0))
(define (kat-nbits    kat) (list-ref kat 1))
(define (kat-rounds   kat) (list-ref kat 2))
(define (kat-iv-name  kat) (list-ref kat 3))
(define (kat-expected kat) (list-ref kat 4))

(define (kat-iv name) (if (eq? name 'free) free-start-iv sha256-iv))

(define (kat-digest kat)
  (digest->hex (shavar-digest/iv (hex->bytevector (kat-hex kat))
                                 (kat-nbits kat)
                                 (kat-iv (kat-iv-name kat))
                                 (kat-rounds kat))))

(define (kat-label kat backend)
  (string-append (kat-hex kat) " " (number->string (kat-nbits kat))
                 " rounds=" (number->string (kat-rounds kat))
                 " iv=" (symbol->string (kat-iv-name kat))
                 " backend=" (symbol->string backend)))

;; Does `thunk` raise an error?  `guard` is R7RS exception handling: it
;; evaluates the body, and if an exception is raised it binds it to `condition`
;; and takes the first matching clause — Scheme's try/except.
(define (raises-error? thunk)
  (guard (condition (#t #t))
    (thunk)
    #f))

(define (selftest-cases)
  (append
   ;; every known answer, once per bitwise backend
   (apply append
          (map (lambda (backend)
                 (map (lambda (kat)
                        (list (kat-label kat backend)
                              (kat-expected kat)
                              (lambda ()
                                (use-bitwise-backend! backend)
                                (kat-digest kat))))
                      known-answers))
               '(native portable)))
   (list
    ;; the two constant tables, recomputed from the primes (SPEC.md 9)
    (list "IV derived from sqrt of the first 8 primes"
          (digest->hex sha256-iv)
          (lambda () (use-bitwise-backend! 'native) (digest->hex (derive-iv))))
    (list "K derived from cbrt of the first 64 primes"
          (apply string-append (map word->hex (vector->list sha256-k)))
          (lambda ()
            (apply string-append (map word->hex (vector->list (derive-k))))))
    ;; the two bitwise backends must agree bit for bit
    (list "portable and native bitwise layers agree"
          "agree"
          (lambda ()
            (let loop ((i 0))
              (if (= i 512)
                  "agree"
                  (let* ((x (u32 (* (+ i 1) 2654435761)))
                         (y (u32 (* (+ i 7) 40503 977))))
                    (if (and (= (portable-and x y) (bitwise-and x y))
                             (= (portable-ior x y) (bitwise-ior x y))
                             (= (portable-xor x y) (bitwise-xor x y))
                             (= (portable-shift x -13) (arithmetic-shift x -13))
                             (= (portable-shift x 5) (arithmetic-shift x 5)))
                        (loop (+ i 1))
                        (string-append "disagree at " (number->string i))))))))
    ;; padding rejects a nonzero trailing bit rather than masking (SPEC.md 5.1)
    (list "b4 5 rejected (low bits 100 are nonzero)"
          "rejected"
          (lambda ()
            (if (raises-error?
                 (lambda () (shavar-digest (hex->bytevector "b4") 5)))
                "rejected" "accepted")))
    (list "b0 5 accepted (low bits zero)"
          "accepted"
          (lambda ()
            (if (raises-error?
                 (lambda () (shavar-digest (hex->bytevector "b0") 5)))
                "rejected" "accepted")))
    (list "b8 5 accepted (low bits zero)"
          "accepted"
          (lambda ()
            (if (raises-error?
                 (lambda () (shavar-digest (hex->bytevector "b8") 5)))
                "rejected" "accepted")))
    (list "byte count must match bit count"
          "rejected"
          (lambda ()
            (if (raises-error?
                 (lambda () (shavar-digest (hex->bytevector "6162") 24)))
                "rejected" "accepted")))
    ;; padded length is always a whole number of 512-bit blocks (SPEC.md 5)
    (list "padding lands on a 512-bit multiple for L = 0..2048"
          "ok"
          (lambda ()
            (let loop ((l 0))
              (cond
               ((> l 2048) "ok")
               ((and (>= (* 512 (padded-block-count l)) (+ l 65))
                     (< (* 512 (padded-block-count l)) (+ l 65 512)))
                (loop (+ l 1)))
               (else (string-append "wrong at L=" (number->string l)))))))
    ;; the trace really is the interior of the digest it reports
    (list "trace HOUT of the last block equals the digest"
          "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
          (lambda ()
            (digest->hex
             (trace-hout
              (shavar-block-trace (hex->bytevector "616263") 24 0
                                  sha256-iv 64)))))
    ;; the recurrence's window really is the eight registers (SPEC.md 3)
    (list "A/E history reproduces the feed-forward"
          "consistent"
          (lambda ()
            (let* ((tr (shavar-block-trace (hex->bytevector "616263") 24 0
                                           sha256-iv 64))
                   (h  (trace-hin tr))
                   (o  (trace-hout tr)))
              (let loop ((i 0))
                (cond
                 ((= i 4) "consistent")
                 ((and (= (vector-ref o i)
                          (w+ (vector-ref h i) (trace-a tr (- 63 i))))
                       (= (vector-ref o (+ i 4))
                          (w+ (vector-ref h (+ i 4)) (trace-e tr (- 63 i)))))
                  (loop (+ i 1)))
                 (else "inconsistent")))))))))

(define (run-selftest)
  (let ((out (current-output-port)))
    (let loop ((cases (selftest-cases)) (passed 0) (failed 0))
      (if (null? cases)
          (begin
            (use-bitwise-backend! 'native)
            (when (zero? failed)
              (write-string "ok " out)
              (write-string (number->string passed) out)
              (newline out))
            (if (zero? failed) 0 1))
          (let* ((c        (car cases))
                 (label    (car c))
                 (expected (cadr c))
                 (actual   (guard (condition (#t "raised an error"))
                             ((list-ref c 2)))))
            (if (string=? actual expected)
                (loop (cdr cases) (+ passed 1) failed)
                (begin
                  (write-string
                   (string-append "FAIL\t" label
                                  "\texpected " expected
                                  "\tactual " actual)
                   out)
                  (newline out)
                  (loop (cdr cases) passed (+ failed 1)))))))))

;;; ===========================================================================
;;; 13. COMMAND LINE  (CLI.md)
;;; ===========================================================================

(define (put s) (write-string s (current-output-port)))
(define (put-line s) (put s) (newline (current-output-port)))

(define (warn s)
  (write-string s (current-error-port))
  (newline (current-error-port)))

;; Exit 2: bad usage, malformed hex, or nonzero trailing bits (CLI.md).
(define (bail s)
  (warn (string-append "shavar: " s))
  (exit 2))

(define usage
  (string-append
   "usage: shavar hash  <hex> <nbits> [rounds]\n"
   "       shavar trace <hex> <nbits> [blockidx] [rounds]\n"
   "       shavar selftest"))

(define (parse-count s what)
  (let ((n (string->number s 10)))
    (if (and n (exact-integer? n) (>= n 0))
        n
        (bail (string-append "bad " what ": " s)))))

(define (parse-rounds s)
  (let ((n (parse-count s "round count")))
    (if (<= n 64) n (bail (string-append "round count above 64: " s)))))

(define (parse-message hex nbits-string)
  (let ((bv    (hex->bytevector hex))
        (nbits (parse-count nbits-string "bit count")))
    (unless bv (bail (string-append "malformed hex: " hex)))
    (values bv nbits)))

;; Print one tab-separated trace record.
(define (trace-line tag index word)
  (put-line (string-append tag "\t" (number->string index) "\t"
                           (word->hex word))))

(define (print-trace tr)
  (let ((rounds (trace-rounds tr)))
    (let loop ((i 0))
      (when (< i 8) (trace-line "HIN" i (vector-ref (trace-hin tr) i)) (loop (+ i 1))))
    ;; W is emitted in full even for reduced rounds: the schedule does not
    ;; depend on the round count (CLI.md).
    (let loop ((t 0))
      (when (< t 64) (trace-line "W" t (vector-ref (trace-w tr) t)) (loop (+ t 1))))
    (let loop ((t -4))
      (when (< t rounds) (trace-line "A" t (trace-a tr t)) (loop (+ t 1))))
    (let loop ((t -4))
      (when (< t rounds) (trace-line "E" t (trace-e tr t)) (loop (+ t 1))))
    (let loop ((t 0))
      (when (< t rounds) (trace-line "T1" t (vector-ref (trace-t1 tr) t)) (loop (+ t 1))))
    (let loop ((t 0))
      (when (< t rounds) (trace-line "T2" t (vector-ref (trace-t2 tr) t)) (loop (+ t 1))))
    (let loop ((i 0))
      (when (< i 8) (trace-line "HOUT" i (vector-ref (trace-hout tr) i)) (loop (+ i 1))))))

(define (cli-display x)
  (cond ((string? x) x)
        ((number? x) (number->string x))
        ((symbol? x) (symbol->string x))
        (else "?")))

;; `guard` turns any error raised by the algorithm — a nonzero trailing bit, a
;; byte/bit count mismatch — into the diagnostic and exit code CLI.md demands,
;; with nothing written to stdout.
(define (with-cli-errors thunk)
  (guard (condition
          ((error-object? condition)
           (bail (apply string-append
                        (error-object-message condition)
                        (map (lambda (x)
                               (string-append " " (cli-display x)))
                             (error-object-irritants condition)))))
          (#t (bail "internal error")))
    (thunk)))

(define (cmd-hash args)
  (if (or (< (length args) 2) (> (length args) 3))
      (bail usage)
      (let-values (((msg nbits) (parse-message (car args) (cadr args))))
        (let ((rounds (if (= (length args) 3) (parse-rounds (list-ref args 2)) 64)))
          (with-cli-errors
           (lambda ()
             (put-line (digest->hex
                        (shavar-digest/iv msg nbits sha256-iv rounds)))))))))

;; Blocks before `blockidx` are compressed with the same reduced round count,
;; so the HIN reported is the chaining value that block genuinely sees in the
;; reduced-round variant `hash <hex> <nbits> <rounds>` computes.
(define (cmd-trace args)
  (if (or (< (length args) 2) (> (length args) 4))
      (bail usage)
      (let-values (((msg nbits) (parse-message (car args) (cadr args))))
        (let* ((n      (length args))
               (idx    (if (>= n 3) (parse-count (list-ref args 2) "block index") 0))
               (rounds (if (>= n 4) (parse-rounds (list-ref args 3)) 64)))
          (with-cli-errors
           (lambda ()
             (when (>= idx (padded-block-count nbits))
               (bail (string-append "block index out of range: "
                                    (number->string idx))))
             (print-trace
              (shavar-block-trace msg nbits idx sha256-iv rounds))))))))

(define (main argv)
  (if (null? argv)
      (bail usage)
      (let ((command (car argv))
            (args    (cdr argv)))
        (cond
         ((string=? command "hash")  (cmd-hash args) (exit 0))
         ((string=? command "trace") (cmd-trace args) (exit 0))
         ((string=? command "selftest")
          (if (null? args)
              (begin
                (warn (string-append "shavar: host bitwise primitives: "
                                     host-bitwise-source))
                (exit (run-selftest)))
              (bail usage)))
         (else (bail (string-append "unknown subcommand: " command
                                    "\n" usage)))))))

;; `command-line` returns the program name followed by its arguments.
;;
;; Run the CLI unless the file was loaded as a library.  R7RS has no portable
;; way for a file to ask whether it is the program being run, so the caller
;; says so explicitly — the same convention, and the same spelling, that
;; sh/shavar.sh uses:  SHAVAR_LIB=1 chibi-scheme -r driver.scm
;; `get-environment-variable` is part of (scheme process-context), already
;; imported above, so this costs no new dependency.
(if (not (get-environment-variable "SHAVAR_LIB"))
    (main (cdr (command-line))))
