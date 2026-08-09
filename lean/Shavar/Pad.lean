/-
# `Shavar.Pad` — V3 and V4, the padding obligations

**Obligation V3 (SPEC.md §8):** *padding lands on a 512-bit multiple, for every
`L`.*
**Obligation V4 (SPEC.md §8):** *padding is injective.*

SPEC.md §5.3 explains why V4 matters: the Merkle–Damgård security argument
needs `pad` to be injective, because two distinct messages padding to the same
bit string would collide for reasons having nothing to do with the compression
function.

## The two levels, and why both are here

SPEC.md §5 describes padding on *bits*; SPEC.md §5.1 says implementations
actually carry *bytes plus a bit count `L`*. Those are different objects and it
is easy to prove something true about the first and quietly assume it transfers
to the second. This file does both explicitly:

* **Bit level.** `padBits` appends a `1`, then `k` zeros, then `L` in 64 bits.
  `padBits_length_mod_512` is V3 and `padBits_injective` is V4.
* **Byte level.** A buffer is a `List (BitVec 8)`. `msgBits` reads `L` bits out
  of it. Crucially, injectivity at the byte level is **false** without a
  well-formedness side condition, and that side condition is exactly the
  validator every implementation in this repository is required to run.

## Why the byte-level statement needs a side condition

Take `L = 5` and the five bits `10110`. SPEC.md §5.1 says the buffer holds
those bits in the *high-order* positions of the single byte, low bits zero:
`0xb0 = 1011 0000`. But `0xb4 = 1011 0100` has the same top five bits. If both
were accepted, they would carry the same 5-bit message and therefore pad
identically — two distinct inputs, one padded string, injectivity destroyed.

This is why SPEC.md §5.1 and CLI.md say implementations must *reject* a final
byte with nonzero padding bits rather than silently masking. The predicate
`WellFormed` below is that rule, and `wellFormedB` — the executable version of
it — is the very function the CLI calls to decide whether to exit 2. The
hypothesis of the injectivity theorem and the runtime check are the same code,
which is the only arrangement in which the theorem says anything about the
program.

`padBits_ne_of_wellFormed_ne` records the failure case as a theorem too: without
`WellFormed`, `0xb0` and `0xb4` at `L = 5` really are a counterexample.
-/
import Shavar.Words

namespace Shavar

/-! ## Big-endian bit strings of a natural number

`natBitsBE n L` is the low `n` bits of `L`, most significant first. This single
function serves two purposes: the 64-bit length field of the padding, and the
eight bits of a byte. Bit order is SPEC.md §1's: most significant first. -/

/-- The low `n` bits of `L`, most significant first. -/
def natBitsBE : Nat → Nat → List Bool
  | 0, _ => []
  | n + 1, L => L.testBit n :: natBitsBE n L

@[simp] theorem natBitsBE_length (n L : Nat) : (natBitsBE n L).length = n := by
  induction n generalizing L with
  | zero => rfl
  | succ n ih => simp [natBitsBE, ih]

/-- Reading `n` bits back tells you the low `n` bits of the number. This is the
technical core of V4: the 64-bit length field is not lost information. -/
theorem natBitsBE_testBit {n L₁ L₂ : Nat} (h : natBitsBE n L₁ = natBitsBE n L₂) :
    ∀ i, i < n → L₁.testBit i = L₂.testBit i := by
  induction n generalizing L₁ L₂ with
  | zero => intro i hi; omega
  | succ n ih =>
      simp only [natBitsBE, List.cons.injEq] at h
      intro i hi
      rcases Nat.lt_or_ge i n with hlt | hge
      · exact ih h.2 i hlt
      · have : i = n := by omega
        subst this; exact h.1

/-- A natural number below `2ⁿ` is determined by its low `n` bits. -/
theorem eq_of_natBitsBE_eq {n L₁ L₂ : Nat}
    (b₁ : L₁ < 2 ^ n) (b₂ : L₂ < 2 ^ n) (h : natBitsBE n L₁ = natBitsBE n L₂) :
    L₁ = L₂ := by
  apply Nat.eq_of_testBit_eq
  intro i
  rcases Nat.lt_or_ge i n with hlt | hge
  · exact natBitsBE_testBit h i hlt
  · have hp : (2 : Nat) ^ n ≤ 2 ^ i := Nat.pow_le_pow_right (by omega) hge
    rw [Nat.testBit_lt_two_pow (by omega), Nat.testBit_lt_two_pow (by omega)]

/-! ## The padding rule of SPEC.md §5 -/

/-- `k` of SPEC.md §5: the smallest non-negative solution of
`L + 1 + k ≡ 448 (mod 512)`.

Written with an extra `+ 512` so the subtraction stays inside the natural
numbers: `L % 512 ≤ 511`, so `447 + 512 - L % 512` is at least `448` and
truncated subtraction never bites. -/
def padZeros (L : Nat) : Nat := (447 + 512 - L % 512) % 512

/-- `padZeros` does solve the congruence of SPEC.md §5 step 2. -/
theorem padZeros_spec (L : Nat) : (L + 1 + padZeros L) % 512 = 448 := by
  unfold padZeros; omega

/-- …and it is the *smallest* solution, as SPEC.md §5 requires. Without this,
`padZeros L + 512` would also satisfy `padZeros_spec` and the padding would be
under-specified. -/
theorem padZeros_least (L k : Nat) (h : (L + 1 + k) % 512 = 448) : padZeros L ≤ k := by
  unfold padZeros; omega

/-- The length of the padded message: `L + 1 + k + 64`. -/
def padLen (L : Nat) : Nat := L + 1 + padZeros L + 64

/--
**V3.** For every bit length `L`, the padded length is a multiple of 512.

`omega` is Lean's decision procedure for linear arithmetic over integers and
naturals; it understands `%` and `/` by literal constants by introducing the
quotient and remainder explicitly. This obligation is exactly the kind of
statement it exists for, and it needs no help.
-/
theorem padLen_mod_512 (L : Nat) : padLen L % 512 = 0 := by
  unfold padLen padZeros; omega

/-- The padded length in bytes, for the implementation. -/
theorem padLen_mod_8 (L : Nat) : padLen L % 8 = 0 := by
  have := padLen_mod_512 L; omega

/-- The bit string a message of length `L` is padded to: the message, a single
`1` bit, `k` zero bits, then `L` as a 64-bit big-endian integer. Transcribed
directly from the three numbered steps of SPEC.md §5. -/
def padBits (m : List Bool) : List Bool :=
  (m ++ (true :: List.replicate (padZeros m.length) false)) ++ natBitsBE 64 m.length

@[simp] theorem padBits_length (m : List Bool) : (padBits m).length = padLen m.length := by
  simp [padBits, padLen]
  omega

/-- **V3, at the level of the actual bit string.** -/
theorem padBits_length_mod_512 (m : List Bool) : (padBits m).length % 512 = 0 := by
  rw [padBits_length]; exact padLen_mod_512 _

/-! ## V4: injectivity -/

/--
**V4.** Padding is injective: two messages with the same padded bit string are
the same message.

The bound `m.length < 2⁶⁴` is the standard's own limit, noted in SPEC.md §5:
the length field is 64 bits wide, so lengths at or above `2⁶⁴` alias and
injectivity genuinely fails there. Stating the hypothesis rather than suppressing
it is the honest form of the claim.

The proof has three moves. First, equal padded strings have equal length, so
`padLen L₁ = padLen L₂`. Second, the last 64 bits of the padded string are the
length field, and dropping the same number of bits from both sides is therefore
`natBitsBE 64 L₁ = natBitsBE 64 L₂`, which forces `L₁ = L₂`. Third, with the
lengths equal the two appended suffixes are literally the same list, so the
prefixes — the messages — must be equal too.
-/
theorem padBits_injective {m₁ m₂ : List Bool}
    (h₁ : m₁.length < 2 ^ 64) (h₂ : m₂.length < 2 ^ 64)
    (h : padBits m₁ = padBits m₂) : m₁ = m₂ := by
  -- Step 1: the padded lengths agree, hence so do the prefix lengths.
  have hlen : padLen m₁.length = padLen m₂.length := by
    rw [← padBits_length, ← padBits_length, h]
  have hpre : (m₁ ++ (true :: List.replicate (padZeros m₁.length) false)).length
            = (m₂ ++ (true :: List.replicate (padZeros m₂.length) false)).length := by
    simp only [List.length_append, List.length_cons, List.length_replicate]
    unfold padLen at hlen
    omega
  -- Step 2: split both sides at that point; the suffixes are the length fields.
  obtain ⟨hprefix, hsuffix⟩ := List.append_inj h hpre
  have hL : m₁.length = m₂.length :=
    eq_of_natBitsBE_eq h₁ h₂ hsuffix
  -- Step 3: with equal lengths the `1`-bit-and-zeros blocks coincide, so cancel.
  rw [hL] at hprefix
  exact List.append_cancel_right hprefix

/-! ## The byte level (SPEC.md §5.1)

Implementations do not receive a `List Bool`. They receive a byte buffer and a
bit count. This section connects the two and states the well-formedness rule
that makes the connection faithful. -/

/-- The eight bits of a byte, most significant first. -/
def byteBits (b : BitVec 8) : List Bool := natBitsBE 8 b.toNat

/-- The bits of a byte buffer, in order. -/
def bytesBits : List (BitVec 8) → List Bool
  | [] => []
  | b :: bs => byteBits b ++ bytesBits bs

@[simp] theorem bytesBits_length (bs : List (BitVec 8)) :
    (bytesBits bs).length = 8 * bs.length := by
  induction bs with
  | nil => rfl
  | cons b bs ih => simp [bytesBits, byteBits, ih]; omega

theorem bytesBits_append (bs cs : List (BitVec 8)) :
    bytesBits (bs ++ cs) = bytesBits bs ++ bytesBits cs := by
  induction bs with
  | nil => rfl
  | cons b bs ih => simp [bytesBits, ih, List.append_assoc]

/-- A byte is determined by its eight bits. -/
theorem byteBits_injective {b₁ b₂ : BitVec 8} (h : byteBits b₁ = byteBits b₂) : b₁ = b₂ := by
  have := eq_of_natBitsBE_eq (n := 8) (L₁ := b₁.toNat) (L₂ := b₂.toNat)
    (by have := b₁.isLt; omega) (by have := b₂.isLt; omega) h
  exact BitVec.eq_of_toNat_eq this

/-- A byte buffer is determined by its bits. -/
theorem bytesBits_injective : ∀ {bs cs : List (BitVec 8)},
    bytesBits bs = bytesBits cs → bs = cs := by
  intro bs
  induction bs with
  | nil =>
      intro cs h
      cases cs with
      | nil => rfl
      | cons c cs =>
          exfalso
          have := congrArg List.length h
          simp [bytesBits, byteBits] at this
          omega
  | cons b bs ih =>
      intro cs h
      cases cs with
      | nil =>
          exfalso
          have := congrArg List.length h
          simp [bytesBits, byteBits] at this
      | cons c cs =>
          simp only [bytesBits] at h
          have hlen : (byteBits b).length = (byteBits c).length := by
            simp [byteBits]
          obtain ⟨hb, hr⟩ := List.append_inj h hlen
          rw [byteBits_injective hb, ih hr]

/-- The `L`-bit message carried by a byte buffer: its first `L` bits. -/
def msgBits (bs : List (BitVec 8)) (L : Nat) : List Bool := (bytesBits bs).take L

/--
The well-formedness rule of SPEC.md §5.1, as an executable predicate: the buffer
holds exactly `⌈L/8⌉` bytes, and every bit beyond position `L` is zero.

This is the function the CLI runs before hashing. `hash b0 5` and `hash b8 5`
are accepted; `hash b4 5` is rejected with exit code 2, because `0xb4` has a set
bit at position 5 which is past the end of a 5-bit message.
-/
def wellFormedB (bs : List (BitVec 8)) (L : Nat) : Bool :=
  bs.length == (L + 7) / 8 && ((bytesBits bs).drop L).all (fun b => !b)

/-- The same rule as a proposition, for use in theorem statements. -/
def WellFormed (bs : List (BitVec 8)) (L : Nat) : Prop := wellFormedB bs L = true

instance (bs : List (BitVec 8)) (L : Nat) : Decidable (WellFormed bs L) :=
  inferInstanceAs (Decidable (_ = true))

/-- An all-zero list is the replicate of `false`. Used to show that two
well-formed buffers of the same length have identical tails. -/
theorem all_false_eq_replicate : ∀ {l : List Bool}, l.all (fun b => !b) = true →
    l = List.replicate l.length false := by
  intro l
  induction l with
  | nil => intro _; rfl
  | cons a l ih =>
      intro h
      simp only [List.all_cons, Bool.and_eq_true, Bool.not_eq_true'] at h
      cases a with
      | false =>
          simp only [List.length_cons, List.replicate_succ, List.cons.injEq, true_and]
          exact ih h.2
      | true => simp at h

/--
**V4 at the byte level.** Two well-formed buffers whose messages pad to the same
bit string are the same buffer with the same bit count.

`WellFormed` is doing real work in this statement: `msgBits [0xb0] 5` and
`msgBits [0xb4] 5` are the same five bits, so without the hypothesis the
conclusion `[0xb0] = [0xb4]` would be false. See
`padBits_ne_of_wellFormed_ne` below.
-/
theorem pad_injective_bytes {bs₁ bs₂ : List (BitVec 8)} {L₁ L₂ : Nat}
    (w₁ : WellFormed bs₁ L₁) (w₂ : WellFormed bs₂ L₂)
    (b₁ : L₁ < 2 ^ 64) (b₂ : L₂ < 2 ^ 64)
    (h : padBits (msgBits bs₁ L₁) = padBits (msgBits bs₂ L₂)) :
    bs₁ = bs₂ ∧ L₁ = L₂ := by
  -- Unpack the executable predicate into its two conjuncts.
  simp only [WellFormed, wellFormedB, Bool.and_eq_true, beq_iff_eq] at w₁ w₂
  obtain ⟨wlen₁, wtail₁⟩ := w₁
  obtain ⟨wlen₂, wtail₂⟩ := w₂
  -- The buffer holds at least `L` bits, so `msgBits` really has length `L`.
  have hml₁ : (msgBits bs₁ L₁).length = L₁ := by
    simp only [msgBits, List.length_take, bytesBits_length, wlen₁]; omega
  have hml₂ : (msgBits bs₂ L₂).length = L₂ := by
    simp only [msgBits, List.length_take, bytesBits_length, wlen₂]; omega
  -- V4 at the bit level gives equality of the messages, hence of the lengths.
  have hmsg : msgBits bs₁ L₁ = msgBits bs₂ L₂ :=
    padBits_injective (by omega) (by omega) h
  have hL : L₁ = L₂ := by rw [← hml₁, ← hml₂, hmsg]
  refine ⟨?_, hL⟩
  -- Both buffers have the same number of bytes, hence the same number of bits.
  have hbytes : bs₁.length = bs₂.length := by rw [wlen₁, wlen₂, hL]
  -- Their tails past bit `L` are all zero, hence equal.
  have htail : (bytesBits bs₁).drop L₁ = (bytesBits bs₂).drop L₂ := by
    rw [all_false_eq_replicate wtail₁, all_false_eq_replicate wtail₂]
    simp only [List.length_drop, bytesBits_length, hbytes, hL]
  -- Head ++ tail on both sides.
  apply bytesBits_injective
  rw [← List.take_append_drop L₁ (bytesBits bs₁), ← List.take_append_drop L₂ (bytesBits bs₂)]
  rw [← msgBits, ← msgBits, hmsg, htail]

/-! ## Why the well-formedness check exists

The following are not decorative. They are the reason CLI.md gives exit code 2
its own row in the table. -/

/-- `0xb0` at `L = 5` is well formed: the low three bits are zero. -/
theorem wf_b0_5 : WellFormed [0xb0] 5 := by decide

/-- `0xb8 = 1011 1000` at `L = 5` is *also* well formed. Its fourth bit is set,
but that bit is inside the five-bit message, not past it. A validator that
rejected this would be wrong in the other direction. -/
theorem wf_b8_5 : WellFormed [0xb8] 5 := by decide

/-- `0xb4 = 1011 0100` at `L = 5` is **not** well formed: bit 5 is set and lies
past the end of the message. This is the input CLI.md requires to be rejected. -/
theorem not_wf_b4_5 : ¬ WellFormed [0xb4] 5 := by decide

/-- And here is what goes wrong if it is not rejected: `0xb0` and `0xb4` carry
the *same* five-bit message, so they pad to the same string while being
different buffers. Injectivity without the well-formedness hypothesis is false,
and this is the witness. -/
theorem padBits_ne_of_wellFormed_ne :
    ([0xb0] : List (BitVec 8)) ≠ [0xb4] ∧
    padBits (msgBits [0xb0] 5) = padBits (msgBits [0xb4] 5) := by
  constructor
  · decide
  · rfl

end Shavar
