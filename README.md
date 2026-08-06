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
>   hand-written **JavaScript** implementation. It's the **bootstrap seed** and
>   the differential oracle: it works today, powers the playground's *Native JS*
>   engine, and is what compiles *this* nimony version the first time.

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

Across the whole corpus exactly one FEATURE is reported, and it is true:
`sizeof` of a non-scalar type. The scalar widths are emitted directly; an
aggregate needs a real layout model — which is what
[`aowlabi`](https://github.com/aoughwl/aowlabi) is — so it throws by name rather
than answering. It appears only inside the system allocation code this backend
replaces, and no corpus program reaches it.

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

Known gap: a closure that captures a local and is **returned** from the proc
owning it. aowljs transpiles it correctly, but nimony's own hexer cannot build it
(`lambdalifting.nim` asserts `env.s != SymId(0)`), so there is no reference output
to compare against. It sits in the corpus as the BLOCKED case and starts comparing
by itself the day the toolchain can run it.

## License

MIT — see [LICENSE](LICENSE).
