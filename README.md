# aowljs

The **nimony-native** `.s.nif` → **native-JavaScript** backend. (Binary and repo
are `aowljs`; `aifjs` remains as a symlink and in the older prose below.)

`aowljs` reads a typed nimony NIF (`.s.nif`) and emits **real JavaScript** — mapping
nimony values onto native JS values (`int`/`float` → number, `string` → string,
`seq` → Array, object → plain object) so the browser's JIT compiles the result.
Near-native speed, readable output.

Mapping onto native values is the whole point and also where the work is: the
target's semantics are not nimony's. A JS object is a reference where a nimony
object is a value; a JS string is UTF-16 where a nimony string is bytes; a JS
number is a double where a nimony `int` is 64-bit. Each of those is a place the
emitter has to do something rather than nothing, and each was silently wrong
before it was made right — see **Status**.

It is written **in nimony**, the way the rest of the toolchain is (`aifparser`,
`aifsem`, `aifi`, `lengcgen`) — not hand-written in JavaScript. That's the point:
aifjs belongs *inside* the ecosystem, and once nimony can compile it, aifjs can
compile **itself**.

> **Two repos, on purpose.**
> - **`aoughwl/aifjs`** (this one) — the nimony implementation. The real one.
> - **[`aoughwl/aifjs-js`](https://github.com/aoughwl/aifjs-js)** — the original
>   hand-written **JavaScript** implementation. It is the **bootstrap seed**: it
>   powers the playground's *Native JS* engine and is what compiles *this* nimony
>   version the first time.
>
> It is **no longer a differential oracle**, which this file used to claim.
> Measured against the current corpus it agrees on **15 of 61** programs — it
> predates methods, exceptions, iterators, object variants, value semantics and
> byte strings, all of which live here now. Treat it as the seed it is; the
> oracle for this backend is **nimony's own output**, which is what
> `tests/run_corpus.sh` compares against.
>
> (Contrast [`aowlc`](https://github.com/aoughwl/aowlc), whose two printers ARE
> near-parity — 62/65 — and so are worth diffing against each other in a gate.
> Same shape, different distance, different right answer.)

## The one idea

`aifjs` is **[`aifi`](https://github.com/aoughwl/aifi) with the interpreter
swapped for a JavaScript emitter.** aifi is already a nimony program that loads a
`.s.nif` (`parseFromBuffer` → `beginRead` → a `Cursor`) and walks it with a
`case n.tagEnum` dispatch (`execStmt`/`execIf`/`execWhile`/`execCall`/…). aifjs
reuses that entire, tested front-end and changes each handler from *"do the
thing"* to *"append the JavaScript"*:

```
aifi:   of IfTagId:   result = execIf(ip, n)       # run the branch
aifjs:  of IfTagId:   emitIf(e, n)                 # print `if(cond){…}`
```

So we don't re-solve NIF reading, symbol resolution, or the type model — we
inherit them from aifi and write only the emitter.

## Bootstrap — how it self-hosts

```
1. seed:   aoughwl/aifjs-js  (hand-written JS)   .s.nif ─▶ native JS   [works today]
2. write:  aoughwl/aifjs     (this, in nimony)   .s.nif ─▶ native JS
3. compile aifjs.nim with nimony               → aifjs.s.nif
4. run aifjs.s.nif through the JS seed          → a fast, native-JS aifjs   ← self-hosted
```

After step 4 the JS seed is disposable: aifjs compiles itself, `aifparser`,
`aifsem`, and your programs — all to fast native JS, all from nimony source.

**Prerequisite the seed still needs:** to transpile *this* (a nimony program that
uses `Table`/`Cursor`/etc.), the JS seed must cover those. `Table` → JS `Map` is
the main remaining item on the seed; the language surface is otherwise complete.

## Building

```sh
./build.sh                # -> bin/aowljs
```

nimony leaves the linked executable inside `<nimcache>/<module-hash>/` rather
than beside the source, so the copy-out is part of the build. The gate calls
`build.sh` first: `bin/aowljs` was once a whole commit behind `src/`, and every
green run was measuring an emitter nobody had rebuilt.

## Status

Working, with a gate that says what it covers.

```sh
tests/run_corpus.sh       # every program, in BOTH modes, against nimony's own output
tests/run_faithful.sh     # the fast/faithful contrast on programs that overflow 2^53
tests/bench.sh            # emitted JS vs the same program hand-written in JS
```

**Every `nimony c` in this repo now goes through the machine-wide lock.** It did
not before: `build.sh` read `${NIMLOCK:-}`, empty unless a caller happened to
export it, and the three test scripts called nimony directly. Two nimony
compiles running at once corrupt each other's link through the shared
`nimcache_static` — a cross-process hazard a private `--nimcache:` does *not*
cover, because the static object is shared across caches. The harnesses were
absorbing it with a five-try retry loop and a `rm -rf` of the cache per attempt,
which is a workaround for a problem that has a fix.

What that cost was not false greens — an empty reference is scored BLOCKED here,
so a corrupt build could not pass — but **false reds and unrepeatable runs**: a
gate whose result depended on whether another instance happened to be compiling.
It also made `bench.sh` report the machine's load rather than the emitter's
speed. The retry loop stays as a backstop; the lock is what stops it firing.

`run_corpus.sh` compiles each program with nimony, transpiles the `.s.nif` in
fast **and** faithful mode, runs both under node and requires a byte match
against nimony's own stdout. It reports three outcomes, not two: **BLOCKED**
means nimony itself could not run the program, which is neither a pass nor a
failure of the emitter and must not be scored as either. The summary declares its
denominator so coverage cannot shrink quietly.

Covered by the corpus: procs, closures over module scope, `var`/`out` params,
control flow including labelled `block`/`break`, `case` over ints, ranges,
strings and enums, exceptions with `finally`/`defer` and unwinding through frames
that do not catch, object variants, distinct types with `{.borrow.}`, generics
(including multi-parameter and generic-over-generic), user `iterator`s, `method`
dispatch over an inheritance chain, enum sets, seq/array/string operations, `$`
conversions, narrow and unsigned integer widths, float formatting, and
multi-module programs.

Two properties are covered because they are wrong *silently* when they are wrong:

- **Value semantics.** A nimony object/tuple/array/seq is a value; assigning one
  copies it. JS aliases. `ref object` must still share — both directions are
  pinned (`value_semantics.nim`, `ref_identity.nim`).
- **Byte strings.** A nimony string is bytes; a JS string is UTF-16 code units.
  Literals are emitted one code unit per byte so `len`, indexing, slicing and
  iteration agree with nimony exactly, and the output is decoded back to text at
  the end (`string_bytes.nim`, `string_print.nim`).

**The value representation is gated against aowlabi.**
[`aowlabi`](https://github.com/aoughwl/aowlabi) states the canonical JS
representation for every type in its marshal matrix, and this backend is the
consumer that turns that claim into real JavaScript values. Its
`tests/jsrepr.sh` declares one global per type, transpiles it here in **both**
modes, runs the emitted module and classifies the value structurally — `typeof`,
`Array.isArray`, `instanceof Set` — never by matching this emitter's own output
text, which would agree by construction. **20/20** — one probe for every
`AbiKind` aowlabi has, with `UncheckedArray` the single declared hold-out (a
trailing flexible member has no standalone value to classify), and that claim
fails by name if a kind is added without a probe. `int64` is the row where the
two modes have to differ (a JS number in fast mode, a BigInt in faithful), which
is the property this backend's `--faithful` flag exists for. `ptr T` is the row
that found a defect: this backend emits the getter/setter box the matrix
describes, and the classifier only knew the `ref object` shape.

**The two corpora are cross-checked, by running each through the other.**
`aowljs/tests/corpus/` and `aowlc/examples/` grew from each other, and running
each backend's fixtures through the other once found 5 defects here and 2 in
aowlc — then nothing kept it up. The two also name the same feature differently
(`calc`/`calculator`, `charsets`/`chars_sets`, `valuesem`/`value_semantics`,
`iters2`/`iterators_nested`), so no tool can tell they overlap and a fixture
added to one side is invisible to the other.

`tests/cross.sh` fixes that without a name map. A map would assert that two
fixtures test the same thing — a claim nobody can check, which rots silently.
The direct question, *does the other backend handle this program?*, needs no
map: run it there. It reports three outcomes (BLOCKED = nimony itself has no
output to compare, so neither backend is being judged), declares a denominator,
and samples **deterministically** — a gate whose corpus changes per run cannot
be compared against its last result. `--sample N` for routine use; the full
sweep is ~45 min and is deliberately not part of `run_corpus.sh`, because a gate
nobody can afford to run is a gate nobody runs.

A fast-mode-only mismatch on a program that passes `--faithful` is reported as
the documented trade-off, not a defect — `e2e_shapes` is that case, exceeding
2^53. Falsified: pointing `$AOWLJS` at `/bin/false` turns it red rather than
quietly passing.

**Speed is measured, not asserted.** `tests/bench.sh` times the emitted JS
against a hand-written JavaScript version of the same program — the emitted code
*is* JavaScript, so 1.00x is the target, not a stretch. Currently: a tight
integer loop **1.01x**, a case-expression in a loop **1.01x**, recursive `fib`
**1.01x**, seq build + indexed sum **0.95x**. It prints and never fails on a
ratio (machines and JIT warm-up vary), but it does fail if the two sides disagree
about the answer — a benchmark computing the wrong thing measures nothing.

That benchmark immediately earned itself, three times:

- an if-EXPRESSION emitted an IIFE, so `proc fib(n: int): int = if n < 2: n else:
  fib(n-1) + fib(n-2)` allocated a closure per call — **3.66x**. It is a
  conditional expression now.
- a case-EXPRESSION assigned to a scalar did the same — **1.20x**. It emits the
  case as statements assigning into the destination.
- `xs.add v` went through the string-capable `__append` even for a known seq —
  **1.16x**. A seq is a JS Array; `.push` is enough.

The `emit` column is the transpile itself, and it is its own regression surface.
The rename table was a linear scan consulted once per symbol *occurrence*, so
emit time grew as **O(n^2.8)**: 346 KB of `.s.nif` took 0.23s, 698 KB took 1.58s
and 1.4 MB took **11.07s**. It is a hash lookup now — the same 1.4 MB takes
**0.19s** — and `tests/bench/bigmodule.nim` (1600 procs, 400 types) is there so
the number stays visible.

**Gaps are reported at emit time, on stderr.** A call to something this backend
never defines used to surface only when the program ran, as `ReferenceError:
paramCount is not defined` — naming neither aowljs nor the nimony symbol. The CLI
now lists them after every module has had its chance to define what an earlier one
called, and exits 0, because the rest of the output is still valid:

```
aifjs: 1 call(s) with no definition — unsupported here:
  paramCount
```

**`sizeof` of an aggregate is answered by aowlabi, not by a table here.** It
used to be the one FEATURE reported across the whole corpus, with the honest
reason "an aggregate needs a real layout model". That model already existed —
[`aowlabi`](https://github.com/aoughwl/aowlabi), gated against nimony's own
`sizeof`, against gcc on the struct aowlc prints, and against gcc `-m32`. What
was missing was the mapping from a NIF type node to a `TypeDesc`, and that
mapping is all `src/abisize.nim` is: **nothing in it computes a size.**

Extending the scalar-width table upward would have been the easy fix and the
wrong one — it would have made this backend the *third* implementation of C
struct layout in the stack, which is the shape that lets a padding defect live
in two of them and get fixed in one. A mapper can be wrong; it cannot be
independently wrong about padding.

**The scalar table is gone too, and removing it fixed a wrong answer.** Keeping
it "for the easy cases" is what a second implementation always looks like, and
it had `cstring` grouped with `string` on the two-word arm: `sizeof(cstring)`
emitted **16** where nimony says **8**. Not an aggregate, not a reported gap —
an ordinary scalar expression, silently wrong, in the half of the code that
looked too simple to be worth unifying. Every type now takes the one path.

`abiSizeOf` returns **-1**, never a guess, so anything still unmapped keeps
being reported rather than silently answered. `tests/corpus/sizeof_agg.nim` is
the gate, and it has a real oracle: nimony folds `sizeof` in its own backend, so
that program's stdout under nimony *is* the right answer. It covers the shapes a
scalar table cannot reach — padding on both sides of a pointer-sized field, an
inherited base, a `{.packed.}` object, a variant's largest branch, a tuple, an
array of a padded element, the two-word `seq`/`string` headers — and the
scalars, because a scalar row is what caught the duplicate. **26/26, both
modes**, with the emitter reporting no gap of any kind for the program.

Two rows exist because they are the only ones that can catch a specific mistake,
and both did:

- `sizeof(cstring)` is the scalar row described above — 16, where nimony says 8.
- `sizeof(set[Wide])` is the only shape whose size comes from an enum's ordinal
  RANGE rather than its width. The first mapper counted a fixed number of slots
  to reach an `efld`'s `(tup ORD "name")` and landed on the type symbol instead,
  so **every ordinal read as 0** — invisible everywhere else, because `enumDesc`
  prefers the explicit width from the enum's base type whenever there is one. A
  21-value enum makes it visible: nimony 3, the unfixed mapper 1.

Falsified: ignoring the `packed` pragma turns that row from 10 into 24.

Three categories are counted rather than listed, because they are deliberate and
would otherwise drown the signal: nimony's manual memory layer (`alloc`,
`arcInc`, …), the ARC hooks (`=destroy` & co), and std/sets' table internals,
which are replaced wholesale by a native JS `Set`. Across the corpus exactly one
program reports, and truthfully: `iterators` reaches std/syncio's C FFI layer
(`fopen`, `c_fwrite`, `fgets`), which is real file I/O this backend does not
implement.

A language feature this target cannot honour at all is reported the same way and
fails where it would have run. `{.emit: "…".}` is inline C: there is no
JavaScript equivalent, and it had been dropped silently — a proc whose emitted C
incremented `result` returned 41 where nimony says 42. It now throws
`aifjs: unsupported: {.emit.} (inline C)`, because a wrong answer is worse than a
clear stop.

Each reported name also gets a stub, so *reaching* one at run time throws
`aifjs: unsupported: fopen` rather than `ReferenceError: fopen is not defined` —
a message that names both this backend and the thing it could not provide. The
stubs are emitted after every module, so a name any of them defines is never
shadowed, and they cost nothing unless reached.

`src/webmain_js.nim`, the browser entry, **does not build and nothing builds
it** — two of its imports no longer resolve (a hardcoded relative path to a
sibling checkout renamed `aifi` → `aowli`, and a `jsffi` module that is not in
the nimony tree at all). It is a design sketch; the playground's *Native JS*
engine is served by `aoughwl/aifjs-js`. Said here so it is not mistaken for part
of the working product.

Known gap: a closure that captures a local and is **returned** from the proc
owning it. aowljs transpiles it correctly, but nimony's own hexer cannot build it
(`lambdalifting.nim` asserts `env.s != SymId(0)`), so there is no reference output
to compare against. It sits in the corpus as the BLOCKED case and starts comparing
by itself the day the toolchain can run it.

## License

MIT — see [LICENSE](LICENSE).
