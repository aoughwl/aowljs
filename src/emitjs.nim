## emitjs.nim — the aifjs emitter: walk a typed `.s.nif` `Cursor` and append the
## equivalent JavaScript. This is `aifi`'s interpreter dispatch with every "run
## it" replaced by "print it", reusing aifi's front-end (nifcursors + the tag
## model + the literal pool).
##
## Built with the aifi build paths (see webtest_js.sh):
##   -p:nimony/src/{lib,nimony,models,gear2}  -p:aifi/src/nifi
##
## STATUS: the computational core compiles + transpiles end-to-end (procs,
## params/result, var/let/const, asgn, if/elif/else, while, ret, arithmetic &
## comparisons with calls, echo, int/string/char literals). The fuller coverage
## (seq/obj/tuple/set/case/generics/var-params/shims) is being ported from the
## JS reference impl (aoughwl/aifjs-js), which is already language-complete.
##
## EXPORT MODES: the default "fast" mode maps every nimony int to JS `number`
## (readable, but silently lossy past 2^53). The opt-in `--faithful` mode maps
## width-64 ints (`int`/`int64`/`uint`/`uint64`) to native `bigint` and
## width-wraps 64-bit arithmetic (`BigInt.asIntN/asUintN`), so int64/uint64 values
## and overflow stay numerically exact. Faithful mode is strictly additive: with
## `faithfulMode == false` every code path below is byte-for-byte the original.

when defined(nimony):
  {.feature: "lenientnils".}

import std/[strutils, sets, tables]
import nifcursors, nifstreams, nimony_model
import tags
import aowlhl/hlwalk   # shared HL-IR shape decoders (local/param/proc/if/case)

type
  JsEmitter = object
    js: string

## enum value (mangled) -> its ordinal, filled by scanEnums before emission.
## (parallel seqs, not a Table: nimony's Table `[]=` is `.raises`.)
var enumKeys: seq[string] = @[]
var enumVals: seq[string] = @[]
proc enumLookup(nm: string): string =
  for i in 0 ..< enumKeys.len:
    if enumKeys[i] == nm: return enumVals[i]
  return ""

## var/out-param boxing (ported from the JS impl). A `var`/`out` param is passed
## by reference, but JS primitives pass by value — so a boxed param is passed as
## an accessor object `{get v(){…}, set v(x){…}}` closing over the caller's lval,
## and inside the callee every `(hderef p)`/`(haddr p)` reads/writes `p.v`.
## `boxProcNames[i]` -> comma-wrapped boxed arg indices (",0,2,"), filled by
## scanProcBoxed. `curBoxed` = the boxed param names of the routine being emitted.
var boxProcNames: seq[string] = @[]
var boxProcIdx: seq[string] = @[]
var curBoxed: seq[string] = @[]
proc boxLookup(nm: string): string =
  for i in 0 ..< boxProcNames.len:
    if boxProcNames[i] == nm: return boxProcIdx[i]
  return ""
proc boxContains(nm: string): bool =
  for b in curBoxed:
    if b == nm: return true
  return false

## Exception support. A ref-object type that transitively inherits `Exception`
## is emitted as a real JS `class … extends …` (so `new T(…)` and `x instanceof T`
## work); regular ref-objects stay plain object literals. `excClassNames` holds the
## mangled *Obj*-type names (the ones referenced by `newobj`/`instanceof`);
## `excClassBase` the parallel JS parent (another exc class, or `Error`). Filled by
## scanExcTypes before emission.
var excClassNames: seq[string] = @[]
var excClassBase: seq[string] = @[]
proc isExcClass(nm: string): bool =
  for c in excClassNames:
    if c == nm: return true
  return false
proc excParent(nm: string): string =
  for i in 0 ..< excClassNames.len:
    if excClassNames[i] == nm: return excClassBase[i]
  return "Error"

## `pendingThrow` stashes the JS expression built when nimony assigns a freshly
## constructed exception to its `exc` threadvar; the following `(raise …)` consumes
## it as `throw <expr>`. `curCatchVar` names the active `catch` binding, so a
## `(raise .)` re-raise becomes `throw <catchVar>`.
var pendingThrow = ""
var curCatchVar = ""

proc emit(e: var JsEmitter; s: string) = e.js.add s

## faithful-export mode (opt-in via the CLI `--faithful` flag). In faithful mode
## width-64 integer types map to JS `bigint` and 64-bit arithmetic is width-wrapped
## with `BigInt.asIntN/asUintN`, so values past 2^53 (and int64/uint64 overflow)
## stay numerically exact. Default false keeps the original all-`number` fast mode
## byte-for-byte — faithful mode is a strictly additive, opt-in path.
var faithfulMode: bool = false
proc setFaithful*(b: bool) = faithfulMode = b
proc isFaithful*(): bool = faithfulMode

## names (mangled) of locals/params that hold a `bigint` in faithful mode — lets
## assignment RHS / conv coercions / return values know when a leaf must be bigint
## (with the `n` suffix) rather than a plain `number`.
var bigVars: seq[string] = @[]
proc bigContains(nm: string): bool =
  for b in bigVars:
    if b == nm: return true
  return false
proc bigAdd(nm: string) =
  if not bigContains(nm): bigVars.add nm

## nimony `char` and `string`/`cstring` both map to a JS `string`, so the emitter
## can't tell them apart from the type node alone in every context. We track which
## locals/params are `char` vs `string` so a `char -> int` conversion emits
## `.charCodeAt(0)` (a JS one-char string has no numeric value) instead of a bogus
## `Number("A")`/`BigInt("A")`.
var charVars: seq[string] = @[]
var strVars: seq[string] = @[]
proc listHas(xs: seq[string]; nm: string): bool =
  for x in xs:
    if x == nm: return true
  return false
proc charAdd(nm: string) =
  if not listHas(charVars, nm): charVars.add nm
proc strAdd(nm: string) =
  if not listHas(strVars, nm): strVars.add nm

## names (mangled) of locals/params whose static type is a float. A JS `number`
## carries no int-vs-float tag at runtime, so `echo`/`$` of a bare float variable
## would print `1` instead of `1.0` and `int(floatVar)` in faithful mode would hit
## `BigInt(3.9)` (RangeError). `looksFloat` consults this so those route correctly.
var floatVars: seq[string] = @[]
proc floatAdd(nm: string) =
  if not listHas(floatVars, nm): floatVars.add nm

## names (mangled) of locals/params whose static type is a std/sets `HashSet`/
## `OrderedSet`. These map to a native JS `Set`, so `len(s)` must emit `.size`
## (not the seq/array `.length`) and a `contains`/`in` test must emit `.has`.
## Filled by emitLocal/collectParams when the declared type is a set instance.
var setVars: seq[string] = @[]
proc setAdd(nm: string) =
  if not listHas(setVars, nm): setVars.add nm
## tuple locals -> the float element indices (base62-free, small): `t[2]` on a
## `(1, "two", 3.0)` must show `3.0`. Parallel seqs keyed by tuple var name.
var tupleVars: seq[string] = @[]
var tupleFloatIdx: seq[seq[int]] = @[]
proc tupleFloatsFor(nm: string): seq[int] =
  for i in 0 ..< tupleVars.len:
    if tupleVars[i] == nm: return tupleFloatIdx[i]
  return @[]
proc hasInt(xs: seq[int]; v: int): bool =
  for x in xs:
    if x == v: return true
  return false

## true iff the proc currently being emitted returns a 64-bit int (faithful mode);
## a bare-literal `return` in such a proc must emit bigint.
var curRetBig: bool = false

## names (mangled) of the current proc's plain (non-boxed) bigint value params
## (faithful mode). Coerced to bigint at function entry so an untyped literal
## argument (`bump(5)` — nimony passes a bare `5`, not `5n`) can't leak a `number`
## into the body's bigint arithmetic and trigger a JS mix-BigInt-and-number error.
var curBigParams: seq[string] = @[]


## JS/TS reserved words that can't stand as a bare identifier — a pretty name that
## lands on one is prefixed with `_`.
var jsReserved: seq[string] = @["if","for","class","return","function","var","let",
  "const","new","delete","typeof","instanceof","in","of","do","while","switch",
  "case","default","break","continue","this","super","null","true","false","void",
  "yield","await","async","static","import","export","extends","enum","try","catch",
  "finally","throw","with","debugger"]
proc isReservedJs(s: string): bool =
  for r in jsReserved:
    if r == s: return true
  return false

## GLOBAL rename table: original full nimony symbol (`fib.1.main`) -> a readable,
## valid JS identifier (`fib`). Parallel seqs (nimony's `Table.[]=` is `.raises`).
## `renameTaken` is the set of pretty names already handed out — pre-seeded with the
## emitter's own runtime helpers / IIFE+loop temporaries so no USER symbol can ever
## shadow them. First sight of a symbol claims its base name; a base already taken by
## a DIFFERENT symbol gets `_2`, `_3`, … until unique (guaranteed collision-free;
## over-disambiguates same-named locals in distinct scopes — acceptable for v1).
var renameKeys: seq[string] = @[]
var renameVals: seq[string] = @[]
var renameTaken: seq[string] = @["__out","__w","__wf","__sf","__fs","__append","__cp","_base","_t","_s","_f",
  "_i64","_u64","_idiv","_imod","_s","_v","_c","_i","_a","_b","_r","_x","_ex","v__i"]
proc prettyTaken(p: string): bool =
  for a in renameTaken:
    if a == p: return true
  return false

## the readable base of a nimony symbol: the segment before the first `.`, sanitized
## to a valid JS identifier and guarded against reserved words / bad starts / empty.
proc prettyBase(name: string): string =
  var res = ""
  var i = 0
  while i < name.len and name[i] != '.':
    let ch = name[i]
    if ch in {'A'..'Z', 'a'..'z', '0'..'9', '_'}: res.add ch
    else: res.add '_'
    inc i
  if res.len == 0: res = "_"
  elif res[0] in {'0'..'9'}: res = "_" & res
  if isReservedJs(res): res = "_" & res
  return res

## a nimony symbol -> a stable, readable, valid JS identifier (see renameTaken).
proc mangle(name: string): string =
  for i in 0 ..< renameKeys.len:
    if renameKeys[i] == name: return renameVals[i]
  let base = prettyBase(name)
  var cand = base
  var k = 2
  while prettyTaken(cand):
    cand = base & "_" & $k
    inc k
  renameKeys.add name
  renameVals.add cand
  renameTaken.add cand
  return cand

## bare callee/operator name — everything before the first `.<digit>`.
proc opName(name: string): string =
  var i = 0
  while i + 1 < name.len:
    if name[i] == '.' and name[i+1] in {'0'..'9'}: return name[0 ..< i]
    inc i
  result = name.strip(leading = false, chars = {'.'})

## true iff `name` carries a generic-instance segment (`.<digits>.I<hash>` — e.g.
## `add.0.I8fahwb`). Instance hashes start with a capital `I`; user-module hashes
## are lowercase (`proxr24ld1`), so a leading capital `I` after the disambiguation
## number reliably marks a monomorphized system/generic instance.
proc isInstanceSym(name: string): bool =
  var i = 0
  while i + 2 < name.len:
    if name[i] == '.' and name[i+1] in {'0'..'9'}:
      var j = i + 1
      while j < name.len and name[j] in {'0'..'9'}: inc j
      if j + 1 < name.len and name[j] == '.' and name[j+1] == 'I': return true
      i = j
    else:
      inc i
  return false

## true iff the callee is a *real* builtin/magic — a system-module symbol
## (`.sysvq0asl`) or a generic instance — rather than a user proc that merely
## shares a base name (`add`/`len`/`newSeq`/`$`/…). Gates every name-keyed magic
## branch so a user `proc add`/`len`/… is emitted as a plain call, not hijacked.
proc isMagicSym(name: string): bool =
  result = name.contains("sysvq0asl") or isInstanceSym(name)

## the mangled names of user `iterator`s (emitted as JS `function*` generators).
## A `for` over one of these consumes it with `for..of`; a `for` over a collection
## indexes it. The two are indistinguishable from the call node alone.
var iterNames: seq[string] = @[]

proc isIterCall(c: Cursor): bool =
  var n = c
  if n.kind == ParLe and (n.tagEnum == CallTagId or n.tagEnum == HcallTagId):
    var p = n; inc p
    if p.kind == Symbol or p.kind == SymbolDef:
      for a in iterNames:
        if a == mangle(pool.syms[p.symId]): return true
  return false

## a fresh, reserved JS identifier derived from `base` — for names the emitter
## invents (method dispatchers and their per-type implementations) rather than
## mangles from a nimony symbol.
proc uniqueJs(base: string): string =
  let b = prettyBase(base)
  var cand = b
  var k = 2
  while prettyTaken(cand):
    cand = b & "_" & $k
    inc k
  renameTaken.add cand
  return cand

## user `method`s. A JS object here is a plain field bag with no prototype, so
## dispatch cannot ride on JS's own: a value of a dispatching type carries a `__t`
## tag naming its type, every method base name gets ONE dispatcher function, and
## the dispatcher walks `__t` up the recorded inheritance chain to the first
## overload that matches.
var objTypeNames: seq[string] = @[]
var objTypeBases: seq[string] = @[]
var methDispKey: seq[string] = @[]     # method base name (opName of the symbol)
var methDispName: seq[string] = @[]    # that group's dispatcher function
var methImplSym: seq[string] = @[]     # one overload's full nimony symbol
var methImplName: seq[string] = @[]    # its emitted function name
var methImplDisp: seq[string] = @[]    # the dispatcher it belongs to
var methImplType: seq[string] = @[]    # its receiver's mangled type name

## the dispatch key of a type node. nimony gives a `ref object` TWO symbols — the
## alias `Circle.0.` and the object `Circle.Obj.0.` — and the constructor, the
## method receiver and the inheritance link do not all use the same one, so the
## unique mangled name cannot join them up. The readable base does, and it is also
## what `__t` should read as.
proc typeKeyOf(c: Cursor): string =
  var n = c
  while n.kind == ParLe and (n.tagEnum == RefTagId or n.tagEnum == MutTagId or
        n.tagEnum == OutTagId or n.tagEnum == SinkTagId or n.tagEnum == LentTagId or
        n.tagEnum == PtrTagId):
    inc n
  if n.kind == Symbol or n.kind == SymbolDef or n.kind == Ident:
    return prettyBase(pool.syms[n.symId])
  return ""

## Does a value of this type need copy-on-assign? nimony objects, tuples, arrays,
## seqs and sets are VALUE types; the JS objects and arrays they map onto are
## references, so a bare `var b = a` aliased them and a later `b.x = …` was
## visible through `a`. Scalars need no copy, strings are immutable in JS, and a
## `ref` must NOT be copied. When the type is not recognised the answer is YES:
## `__cp` is the identity on anything that turns out not to have needed it, so
## over-answering costs a call and under-answering is a wrong result.
proc copyNeeded(c: Cursor): bool =
  var n = c
  while n.kind == ParLe and (n.tagEnum == MutTagId or n.tagEnum == OutTagId or
        n.tagEnum == SinkTagId or n.tagEnum == LentTagId or n.tagEnum == RangetypeTagId):
    inc n
  case n.kind
  of ParLe:
    let t = n.tagEnum
    return not (t == RefTagId or t == PtrTagId or t == ITagId or t == UTagId or
                t == FTagId or t == CTagId or t == BoolTagId or t == StringTagId or
                t == CstringTagId or t == EnumTagId or t == ProctypeTagId)
  of Symbol, SymbolDef, Ident:
    let nm = opName(pool.syms[n.symId])
    return not (nm == "int" or nm == "int8" or nm == "int16" or nm == "int32" or
                nm == "int64" or nm == "uint" or nm == "uint8" or nm == "uint16" or
                nm == "uint32" or nm == "uint64" or nm == "float" or nm == "float32" or
                nm == "float64" or nm == "char" or nm == "bool" or nm == "string" or
                nm == "cstring" or nm == "Natural" or nm == "Positive")
  else:
    return false

## Is this expression an LVALUE — something that names storage someone else can
## still reach? Those are what have to be copied on assignment. A literal, a
## constructor or an arithmetic result is already a fresh value.
proc isLvalueExpr(c: Cursor): bool =
  var n = c
  case n.kind
  of Symbol, SymbolDef, Ident: return true
  of ParLe:
    let t = n.tagEnum
    return t == DotTagId or t == DdotTagId or t == AtTagId or t == ArratTagId or
           t == TupatTagId or t == HderefTagId or t == HaddrTagId or t == DerefTagId or
           t == ExprTagId
  else: return false

proc objBaseOf(t: string): string =
  for i in 0 ..< objTypeNames.len:
    if objTypeNames[i] == t: return objTypeBases[i]
  return ""

## does `t`, or anything it inherits from, have a method? Only those types need a
## `__t` tag — tagging everything would put the field on every Table/HashSet node.
proc dispatchesOn(t: string): bool =
  var cur = t
  var guard = 0
  while cur.len > 0 and guard < 64:
    for x in methImplType:
      if x == cur: return true
    cur = objBaseOf(cur)
    inc guard
  return false

proc methImplFor(sym: string): string =
  for i in 0 ..< methImplSym.len:
    if methImplSym[i] == sym: return methImplName[i]
  return ""

## the mangled Obj-class name behind a `(ref X (notnil))` | `X` type node (the
## form `newobj`/`instanceof` reference); "" if it is not a plain symbol/ref.
proc excRefClassName(c: Cursor): string =
  var n = c
  if n.kind == ParLe and n.tagEnum == RefTagId: inc n
  if n.kind == Symbol or n.kind == SymbolDef or n.kind == Ident:
    result = mangle(pool.syms[n.symId])
  else:
    result = ""

## true iff the cursor is nimony's `exc` exception threadvar (a system global).
proc isExcThreadvar(c: Cursor): bool =
  if c.kind == Symbol or c.kind == SymbolDef or c.kind == Ident:
    let nm = pool.syms[c.symId]
    return opName(nm) == "exc" and nm.contains("sysvq0asl")
  return false

## classify a type node (unwrapping mut/out/sink/lent/rangetype) as char / string.
## 1 = char, 2 = string/cstring, 0 = neither.
proc typeNamed(c: Cursor): int =
  var n = c
  while n.kind == ParLe and (n.tagEnum == MutTagId or n.tagEnum == OutTagId or
        n.tagEnum == SinkTagId or n.tagEnum == LentTagId or n.tagEnum == RangetypeTagId):
    inc n
  case n.kind
  of Symbol, SymbolDef, Ident:
    let nm = opName(pool.syms[n.symId])
    if nm == "char": return 1
    elif nm == "string" or nm == "cstring": return 2
    else: return 0
  of ParLe:
    let t = n.tagEnum
    if t == CTagId: return 1
    elif t == StringTagId or t == CstringTagId: return 2
    else: return 0
  else: return 0

## true iff a type node denotes a std/sets `HashSet`/`OrderedSet` (unwrapping
## mut/out/sink/lent/rangetype). Such a value maps to a native JS `Set`.
proc isSetType(c: Cursor): bool =
  var n = c
  while n.kind == ParLe and (n.tagEnum == MutTagId or n.tagEnum == OutTagId or
        n.tagEnum == SinkTagId or n.tagEnum == LentTagId or n.tagEnum == RangetypeTagId):
    inc n
  if n.kind == Symbol or n.kind == SymbolDef or n.kind == Ident:
    let nm = opName(pool.syms[n.symId])
    return nm == "HashSet" or nm == "OrderedSet"
  return false

## the JS value a `var x: T` with no initializer starts at. This used to be a
## blanket `0`, which is only right for the numeric types: `var grid: array[2,
## array[3, int]]` became the *number* 0, so `grid[1][2] = 5` wrote a property
## onto a primitive and evaporated, and `var s: string` echoed "0".
proc defaultVal(c: Cursor): string =
  var n = c
  while n.kind == ParLe and (n.tagEnum == MutTagId or n.tagEnum == OutTagId or
        n.tagEnum == SinkTagId or n.tagEnum == LentTagId):
    inc n
  if isSetType(n): return "new Set()"
  case typeNamed(n)
  of 1: return "\"\\u0000\""                 # char — nimony's default is '\0'
  of 2: return "\"\""
  else: discard
  case n.kind
  of Symbol, SymbolDef, Ident:
    let nm = opName(pool.syms[n.symId])
    if nm == "seq": return "[]"
    elif nm == "bool": return "false"
    return "0"
  of ParLe:
    let t = n.tagEnum
    if t == BoolTagId: return "false"
    elif t == ArrayTagId:
      inc n                                  # (array ELEM (rangetype BASE lo hi))
      let elem = defaultVal(n)
      skip n
      var count = 0
      if n.kind == ParLe and n.tagEnum == RangetypeTagId:
        inc n; skip n                        # past the rangetype's base type
        var lo = 0
        var hi = -1
        if n.kind == IntLit: lo = int(pool.integers[n.intId])
        skip n
        if n.kind == IntLit: hi = int(pool.integers[n.intId])
        count = hi - lo + 1
        if count < 0: count = 0
      # Array.from, not .fill: a nested array default must be a fresh value per
      # slot. `.fill([])` would alias one array into every row.
      return "Array.from({length: " & $count & "}, () => " & elem & ")"
    else: return "0"
  else: return "0"

## true iff the expression (unwrapping a leading haddr/hderef) is a known set var
## — the set operand of an `incl`/`excl`/`contains`/`len` magic call.
proc operandIsSet(c: Cursor): bool =
  var n = c
  if n.kind == ParLe and (n.tagEnum == HaddrTagId or n.tagEnum == HderefTagId):
    inc n
  if n.kind == Symbol or n.kind == SymbolDef or n.kind == Ident:
    return listHas(setVars, mangle(pool.syms[n.symId]))
  return false

## at a `(call CALLEE ARG0 …)` with `n` positioned on the callee symbol, is the
## first argument a set var? (peeks a copy; does not advance `n`).
proc callFirstArgIsSet(c: Cursor): bool =
  var p = c; inc p                     # past the callee -> first arg
  operandIsSet(p)

## true iff the conversion source `n` yields a JS `string` that models a nimony
## `char` — a char var/param, a `CharLit`, an index into a `string`, or a nested
## char-producing conv. Such a source needs `.charCodeAt(0)` to become an int.
proc sourceIsChar(n: Cursor): bool =
  case n.kind
  of CharLit: return true
  of Symbol, SymbolDef, Ident: return listHas(charVars, mangle(pool.syms[n.symId]))
  of ParLe:
    let t = n.tagEnum
    if t == AtTagId or t == ArratTagId:
      var d = n; inc d
      if d.kind == Symbol or d.kind == SymbolDef or d.kind == Ident:
        return listHas(strVars, mangle(pool.syms[d.symId]))
      return false
    elif t == CallTagId or t == HcallTagId or t == CmdTagId:
      var d = n; inc d                        # callee
      if (d.kind == Symbol or d.kind == SymbolDef) and opName(pool.syms[d.symId]) == "[]":
        inc d                                 # container arg
        if d.kind == Symbol or d.kind == SymbolDef or d.kind == Ident:
          return listHas(strVars, mangle(pool.syms[d.symId]))
      return false
    elif t == ConvTagId or t == HconvTagId:
      var d = n; inc d
      return d.kind == ParLe and d.tagEnum == CTagId
    else: return false
  else: return false

const hexDigits = "0123456789abcdef"

proc jsString(s: string): string =
  ## A nimony string/char literal as a JS string literal. Control bytes are
  ## escaped rather than passed through: `'\0'` used to emit a *raw* NUL into the
  ## JS source, which is legal JS but does not survive anything that touches the
  ## text between here and the engine (a pipe, a shell capture, an HTML <script>),
  ## and silently became the empty string when it didn't.
  result = "\""
  for ch in s:
    case ch
    of '"': result.add "\\\""
    of '\\': result.add "\\\\"
    of '\n': result.add "\\n"
    of '\t': result.add "\\t"
    of '\r': result.add "\\r"
    else:
      let b = int(ch)
      if b < 0x20 or b == 0x7f:
        result.add "\\u00"
        result.add hexDigits[(b shr 4) and 0xf]
        result.add hexDigits[b and 0xf]
      else:
        result.add ch
  result.add "\""

# forward decls (same shape as interp.nim)
proc emitStmt(e: var JsEmitter; n: var Cursor)
proc emitExpr(e: var JsEmitter; n: var Cursor; wantBig = false)
proc exprToStr(n: var Cursor; wantBig = false): string
proc emitCase(e: var JsEmitter; n: var Cursor; asExpr: bool)
proc emitBoxArg(e: var JsEmitter; n: var Cursor)
proc emitArrow(e: var JsEmitter; n: var Cursor)
proc collExpr(n: var Cursor): string

## the JS operator for a binary-arithmetic/comparison tag, or "" if not one.
proc binOp(t: TagEnum): string =
  if t == AddTagId: " + "
  elif t == SubTagId: " - "
  elif t == MulTagId: " * "
  elif t == LtTagId: " < "
  elif t == LeTagId: " <= "
  elif t == EqTagId: " === "
  elif t == NeqTagId: " !== "
  elif t == BitandTagId: " & "
  elif t == BitorTagId: " | "
  elif t == BitxorTagId: " ^ "
  elif t == ShlTagId: " << "
  elif t == ShrTagId: " >> "
  elif t == AshrTagId: " >> "
  else: ""

proc isCallTag(t: TagEnum): bool =
  t == CallTagId or t == CmdTagId or t == InfixTagId or t == PrefixTagId or t == HcallTagId

## best-effort "is this echoed value a float?" (peeks a Cursor copy) — a float
## literal, an arithmetic op with a `(f …)` result type, or a float-returning
## math call. Used only to keep integer-valued floats printing as `7.0`, not `7`.
proc isFloatType(c: Cursor): bool =
  var n = c
  while n.kind == ParLe and (n.tagEnum == MutTagId or n.tagEnum == OutTagId or
        n.tagEnum == SinkTagId or n.tagEnum == LentTagId or n.tagEnum == RangetypeTagId):
    inc n
  if n.kind == ParLe and n.tagEnum == FTagId: return true
  if n.kind == Symbol or n.kind == SymbolDef or n.kind == Ident:
    let nm = opName(pool.syms[n.symId])
    return nm == "float" or nm == "float32" or nm == "float64" or
           nm == "cfloat" or nm == "cdouble"
  return false

## the float element indices of a `(tuple T0 T1 …)` type node ((kv f T) for named).
proc tupleFloatIndices(c: Cursor): seq[int] =
  result = @[]
  var n = c
  while n.kind == ParLe and (n.tagEnum == MutTagId or n.tagEnum == OutTagId or
        n.tagEnum == SinkTagId or n.tagEnum == LentTagId):
    inc n
  if not (n.kind == ParLe and n.tagEnum == TupleTagId): return
  inc n
  var idx = 0
  while n.kind != ParRi:
    var el = n
    if el.kind == ParLe and el.tagEnum == KvTagId:
      inc el; skip el                          # (kv field TYPE) -> TYPE
    if isFloatType(el): result.add idx
    skip n
    inc idx

proc looksFloat(c: Cursor): bool =
  if c.kind == FloatLit: return true
  if c.kind == Symbol or c.kind == SymbolDef or c.kind == Ident:
    return listHas(floatVars, mangle(pool.syms[c.symId]))
  if c.kind != ParLe: return false
  let t = c.tagEnum
  if t == TupatTagId:                          # (tupat tupleVar idx) into a float slot
    var d = c; inc d
    if d.kind == Symbol or d.kind == SymbolDef or d.kind == Ident:
      let fs = tupleFloatsFor(mangle(pool.syms[d.symId]))
      if fs.len > 0:
        skip d                                 # past the tuple operand
        if d.kind == IntLit: return hasInt(fs, int(pool.integers[d.intId]))
    return false
  if t == AddTagId or t == SubTagId or t == MulTagId or t == DivTagId:
    var d = c; inc d
    return d.kind == ParLe and d.tagEnum == FTagId
  if t == CallTagId or t == HcallTagId:
    var d = c; inc d
    let callee = if d.kind == Symbol or d.kind == SymbolDef: pool.syms[d.symId] else: ""
    let nm = opName(callee)
    return nm == "sqrt" or nm == "pow" or nm == "sin" or nm == "cos" or nm == "tan" or
           nm == "exp" or nm == "ln" or nm == "hypot" or nm == "floor" or nm == "ceil"
  if t == ConvTagId or t == HconvTagId:      # float(x) / conv-to-float -> show N.0
    var d = c; inc d
    return d.kind == ParLe and d.tagEnum == FTagId
  return false

proc joinList(xs: seq[string]; sep: string): string =
  result = ""
  var first = true
  for x in xs:
    if not first: result.add sep
    first = false
    result.add x

## classify a nimony type node for faithful mode: 0 = not a 64-bit int type,
## 1 = signed 64-bit (int/int64), 2 = unsigned 64-bit (uint/uint64). Default `int`
## and `int64` both encode as `(i 64)`; `uint`/`uint64` as `(u 64)`.
proc int64Kind(c: Cursor): int =
  var n = c
  case n.kind
  of Symbol, SymbolDef, Ident:
    let nm = opName(pool.syms[n.symId])
    if nm == "int" or nm == "int64" or nm == "Natural" or nm == "Positive": return 1
    elif nm == "uint" or nm == "uint64": return 2
    else: return 0
  of ParLe:
    let t = n.tagEnum
    if t == ITagId or t == UTagId:
      inc n
      if n.kind == IntLit and pool.integers[n.intId] == 64:
        return (if t == ITagId: 1 else: 2)
      return 0
    elif t == MutTagId or t == OutTagId or t == SinkTagId or t == LentTagId or
         t == RangetypeTagId:
      inc n
      return int64Kind(n)
    else: return 0
  else: return 0

## in faithful mode, does this expression already evaluate to a `bigint`? Used to
## decide conv coercions (bigint->number needs `Number(...)`) and asgn/return leaves.
proc producesBig(c: Cursor): bool =
  if not faithfulMode: return false
  var n = c
  case n.kind
  of Symbol, SymbolDef, Ident:
    return bigContains(mangle(pool.syms[n.symId]))
  of ParLe:
    let t = n.tagEnum
    if t == SufTagId:
      inc n; skip n                     # (suf LIT "suffix")
      if n.kind == StringLit:
        let s = pool.strings[n.litId]
        return s == "i64" or s == "u64"
      return false
    elif t == AddTagId or t == SubTagId or t == MulTagId or t == DivTagId or
         t == ModTagId or t == ShlTagId or t == ShrTagId or t == AshrTagId or
         t == BitandTagId or t == BitorTagId or t == BitxorTagId or t == NegTagId or
         t == ConvTagId or t == HconvTagId:
      inc n                             # arithmetic magics carry type as first child
      return int64Kind(n) > 0
    elif t == HderefTagId or t == HaddrTagId or t == ExprTagId:
      inc n
      return producesBig(n)
    else:
      return false
  else:
    return false

proc emitStmts(e: var JsEmitter; n: var Cursor) =
  inc n
  while n.kind != ParRi: emitStmt(e, n)
  consumeParRi n

proc emitBigOperand(e: var JsEmitter; n: var Cursor) =
  ## An operand of a 64-bit op in faithful mode. `wantBig` only suffixes an int
  ## *literal*; anything the emitter can't prove is already a bigint — a tuple
  ## slot, a field, a call result — arrives as a plain `number` and makes
  ## `BigInt.asIntN` throw "Cannot convert 3 to a BigInt". `BigInt(x)` is the
  ## identity on a bigint, so coercing whatever we can't prove costs nothing.
  if n.kind == IntLit or n.kind == UIntLit or producesBig(n):
    emitExpr(e, n, true)
  else:
    e.emit("BigInt("); emitExpr(e, n, true); e.emit(")")

proc emitBinop(e: var JsEmitter; n: var Cursor; op: string; t: TagEnum) =
  ## (op TYPE a b) -> (a op b). A narrow machine int has to be renormalised after
  ## the op, because JS is not one: `+`/`*` grow past the width, and every bitwise
  ## op yields a *signed 32-bit* number. So an unsigned type gets `>>> 0` (u32) or
  ## a mask, and a narrow signed type a sign-extending shift pair. `shr` on an
  ## unsigned type must be JS `>>>`: `>>` sign-extends, which turned
  ## `4000000000'u32 shr 8` into -1152216 instead of 15625000.
  inc n
  var width = 0
  var unsigned = false
  var big64 = 0                   # 0=no, 1=signed, 2=unsigned (faithful mode)
  if n.kind == ParLe and (n.tagEnum == ITagId or n.tagEnum == UTagId):
    unsigned = n.tagEnum == UTagId
    var d = n; inc d
    if d.kind == IntLit: width = int(pool.integers[d.intId])
    if width == 64 and faithfulMode:
      big64 = if unsigned: 2 else: 1
  skip n                          # the type node
  var jsOp = op
  if unsigned and width > 0 and width <= 32 and t == ShrTagId:
    jsOp = " >>> "
  let narrow = width > 0 and width <= 32 and
               (t == AddTagId or t == SubTagId or t == MulTagId or t == ShlTagId or
                t == BitandTagId or t == BitorTagId or t == BitxorTagId)
  if narrow:
    var pre = "("
    var post = ""
    if unsigned:
      if width == 32: post = " >>> 0)"
      elif width == 16: post = " & 0xFFFF)"
      else: post = " & 0xFF)"
    else:
      if width == 32: post = " | 0)"
      elif width == 16: pre = "(("; post = " << 16) >> 16)"
      else: pre = "(("; post = " << 24) >> 24)"
    e.emit(pre)
    if t == MulTagId:
      e.emit("Math.imul("); emitExpr(e, n); e.emit(", "); emitExpr(e, n); e.emit(")")
    else:
      e.emit("("); emitExpr(e, n); e.emit(jsOp); emitExpr(e, n); e.emit(")")
    e.emit(post)
  elif big64 > 0:
    # operands must both be bigint; add/sub/mul/shl and the bitwise ops can exceed
    # the 64-bit range so wrap them, comparisons and >> stay bare.
    let needWrap = t == AddTagId or t == SubTagId or t == MulTagId or t == ShlTagId or
                   t == BitandTagId or t == BitorTagId or t == BitxorTagId
    let wrapper = if big64 == 1: "_i64" else: "_u64"
    if needWrap: e.emit(wrapper & "(") else: e.emit("(")
    emitBigOperand(e, n); e.emit(op); emitBigOperand(e, n)
    e.emit(")")
  else:
    e.emit("("); emitExpr(e, n); e.emit(jsOp); emitExpr(e, n); e.emit(")")
  consumeParRi n

## emit an array index. In faithful mode an index may be a `bigint` (64-bit int),
## which JS rejects as an index, so coerce with `Number(...)` (a no-op for numbers).
proc emitIdx(e: var JsEmitter; n: var Cursor) =
  if faithfulMode:
    e.emit("Number("); emitExpr(e, n); e.emit(")")
  else:
    emitExpr(e, n)

proc emitBoxArg(e: var JsEmitter; n: var Cursor) =
  ## Box a var/out argument: (haddr LVAL) -> an accessor closing over the lval, so
  ## the callee's writes to `.v` land back on the caller's variable.
  var lv = ""
  if n.kind == ParLe and (n.tagEnum == HaddrTagId or n.tagEnum == HderefTagId):
    inc n
    lv = exprToStr(n)
    while n.kind != ParRi: skip n
    consumeParRi n
  else:
    lv = exprToStr(n)
  e.emit("{get v(){return " & lv & ";}, set v(_x){" & lv & " = _x;}}")

proc setOperandStr(n: var Cursor): string =
  ## consume one set operand (a `(haddr s)` from a `var`-param call, or a bare `s`)
  ## and return its JS expression — the receiver of a native `Set` method.
  if n.kind == ParLe and (n.tagEnum == HaddrTagId or n.tagEnum == HderefTagId):
    inc n
    result = exprToStr(n)
    while n.kind != ParRi: skip n
    consumeParRi n
  else:
    result = exprToStr(n)

proc emitCall(e: var JsEmitter; n: var Cursor) =
  ## (call CALLEE ARGS…) / (cmd …). echo -> write(stdout,X) -> __w(X); the common
  ## seq/string builtins map to native JS; everything else is a plain call.
  inc n
  let callee = if n.kind == Symbol or n.kind == SymbolDef: pool.syms[n.symId] else: ""
  let name = opName(callee)
  let magic = isMagicSym(callee)   # gate name-keyed magics: user procs must not be hijacked
  if name == "write":
    skip n; skip n                # callee, stdout
    e.emit(if looksFloat(n): "__wf(" else: "__w(")
    emitExpr(e, n); e.emit(")")
    while n.kind != ParRi: skip n
  elif name == "len" and magic:
    # `len` yields a 64-bit int. In faithful mode that is a `bigint`, so wrap the
    # native `.length` (a JS `number`) — otherwise `xs.len - 1` mixes bigint with
    # number (the surrounding int64 arithmetic emits its `1` as `1n`). emitIdx
    # coerces back with Number(), so index uses stay correct. A HashSet maps to a
    # native `Set`, whose element count is `.size` (NOT `.length`).
    let prop = if callFirstArgIsSet(n): ".size)" else: ".length)"
    skip n
    if faithfulMode: e.emit("BigInt(")
    e.emit("("); emitExpr(e, n); e.emit(prop)
    if faithfulMode: e.emit(")")
    while n.kind != ParRi: skip n
  elif name == "initHashSet" and magic:
    skip n; e.emit("new Set()")               # std/sets: fresh empty HashSet
    while n.kind != ParRi: skip n
  elif name == "incl" and magic and callFirstArgIsSet(n):
    skip n                                     # callee
    let sv = setOperandStr(n)                  # set receiver (drop the (haddr …))
    e.emit("(" & sv & ".add("); emitExpr(e, n); e.emit("))")
    while n.kind != ParRi: skip n
  elif name == "excl" and magic and callFirstArgIsSet(n):
    skip n                                     # callee
    let sv = setOperandStr(n)
    e.emit("(" & sv & ".delete("); emitExpr(e, n); e.emit("))")
    while n.kind != ParRi: skip n
  elif name == "contains" and magic and callFirstArgIsSet(n):
    skip n                                     # callee
    let sv = setOperandStr(n)                  # `x in s` -> s.has(x)
    e.emit("(" & sv & ".has("); emitExpr(e, n); e.emit("))")
    while n.kind != ParRi: skip n
  elif name == "[]" and magic:
    skip n                                   # callee
    let container = exprToStr(n)             # container (string/seq/array)
    if n.kind == ParLe and n.tagEnum == InfixTagId:
      # slice: (infix `..`/`..<` lo hi) -> JS .slice(lo, hi(+1))
      var ic = n
      inc ic
      let sliceOp = opName(if ic.kind == Symbol or ic.kind == Ident: pool.syms[ic.symId] else: "")
      inc ic
      let lo = exprToStr(ic)
      let hi = exprToStr(ic)
      let lo2 = if faithfulMode: "Number(" & lo & ")" else: lo
      let hi2 = if faithfulMode: "Number(" & hi & ")" else: hi
      # `..` is inclusive (end = hi+1), `..<` is exclusive (end = hi)
      let endStr = if sliceOp == "..<": hi2 else: "(" & hi2 & " + 1)"
      e.emit(container & ".slice(" & lo2 & ", " & endStr & ")")
      skip n                                 # the slice infix arg
    else:
      e.emit("(" & container & "["); emitIdx(e, n); e.emit("])")
    while n.kind != ParRi: skip n
  elif name == "[]=" and magic:
    skip n                                   # callee
    var container = ""                       # (haddr LVAL) | LVAL
    if n.kind == ParLe and (n.tagEnum == HaddrTagId or n.tagEnum == HderefTagId):
      inc n; container = exprToStr(n)
      while n.kind != ParRi: skip n
      consumeParRi n
    else:
      container = exprToStr(n)
    e.emit("(" & container & "["); emitIdx(e, n); e.emit("] = "); emitExpr(e, n); e.emit(")")
    while n.kind != ParRi: skip n
  elif name == "add" and magic:
    skip n
    let lv = exprToStr(n)                    # target: seq push, or string reassign
    e.emit("(" & lv & " = __append(" & lv & ", ")
    # `s.add p` stores a COPY of p; otherwise a later `p.x = …` reaches into the seq
    let cpv = isLvalueExpr(n)
    if cpv: e.emit("__cp(")
    emitExpr(e, n)
    if cpv: e.emit(")")
    e.emit("))")
    while n.kind != ParRi: skip n
  elif (name == "newSeq" or name == "newSeqUninit" or name == "newSeqOfCap" or
       name == "newSeqUninitialized") and magic:
    skip n                                   # seq constructors -> JS array
    if name == "newSeq" and n.kind != ParRi:
      e.emit("new Array("); emitIdx(e, n); e.emit(").fill(0)")  # newSeq(n) -> n zeros
    else:
      e.emit("[]")
    while n.kind != ParRi: skip n
  elif name == "newString" and magic:
    skip n; e.emit("\"\"")                    # newString(n) -> empty string
    while n.kind != ParRi: skip n
  elif name == "$" and magic:
    skip n
    if looksFloat(n): (e.emit("__sf("); emitExpr(e, n); e.emit(")"))
    else: (e.emit("String("); emitExpr(e, n); e.emit(")"))
    while n.kind != ParRi: skip n
  elif (name == "==" or name == "!=" or name == "<" or name == "<=" or
        name == ">" or name == ">=") and magic:
    # operator-overload comparison emitted as a call (e.g. string ==/</>): JS
    # strings compare lexicographically, so map to the native operator.
    let jsOp = (if name == "==": " === " elif name == "!=": " !== " else: " " & name & " ")
    skip n; e.emit("("); emitExpr(e, n); e.emit(jsOp); emitExpr(e, n); e.emit(")")
    while n.kind != ParRi: skip n
  elif name == "inc" and magic:
    skip n; e.emit("("); emitExpr(e, n)
    if n.kind != ParRi: (e.emit(" += "); emitExpr(e, n)) else: e.emit(" += 1")
    e.emit(")")
    while n.kind != ParRi: skip n
  elif name == "&" and magic:
    skip n; e.emit("("); emitExpr(e, n); e.emit(" + "); emitExpr(e, n); e.emit(")")
    while n.kind != ParRi: skip n
  elif name == "chr" and magic:
    skip n; e.emit("String.fromCharCode("); emitExpr(e, n); e.emit(")")
    while n.kind != ParRi: skip n
  elif name == "ord" and magic:
    skip n; e.emit("("); emitExpr(e, n); e.emit(").charCodeAt(0)")
    while n.kind != ParRi: skip n
  elif (name == "filter" or name == "map") and magic:
    # std/sequtils higher-order funcs -> native JS Array.filter/.map. Shape:
    # (call filter/map INSTANCE (hcall toOpenArray SEQ) CLOSURE). The collection is
    # wrapped in toOpenArray/items — collExpr unwraps it back to the seq; the closure
    # is emitted as a JS arrow (via the (expr (stmts (proc …) ref)) path). Native
    # .filter/.map ignore the extra (index, array) callback args, so fixed-arity
    # arrows are safe.
    skip n                                   # callee
    let coll = collExpr(n)                    # unwrap toOpenArray -> the seq
    e.emit("(" & coll & "." & name & "(")
    emitExpr(e, n)                            # the predicate/transform closure
    e.emit("))")
    while n.kind != ParRi: skip n
  elif name == "abs" and magic:
    skip n; e.emit("Math.abs("); emitExpr(e, n); e.emit(")")
    while n.kind != ParRi: skip n
  elif (name == "min" or name == "max") and magic:
    skip n; e.emit("Math." & name & "(")
    var mfirst = true
    while n.kind != ParRi:
      if not mfirst: e.emit(", ")
      mfirst = false
      emitExpr(e, n)
    e.emit(")")
  elif name == "sqrt" or name == "floor" or
       name == "ceil" or name == "round" or name == "trunc" or name == "sin" or
       name == "cos" or name == "tan" or name == "exp" or name == "ln" or name == "pow":
    let jn = if name == "ln": "log" else: name    # math.* -> Math.*
    skip n; e.emit("Math." & jn & "(")
    var mfirst = true
    while n.kind != ParRi:
      if not mfirst: e.emit(", ")
      mfirst = false
      emitExpr(e, n)
    e.emit(")")
  elif name == "toLowerAscii" or name == "toLower":
    skip n; e.emit("("); emitExpr(e, n); e.emit(").toLowerCase()")
    while n.kind != ParRi: skip n
  elif name == "toUpperAscii" or name == "toUpper":
    skip n; e.emit("("); emitExpr(e, n); e.emit(").toUpperCase()")
    while n.kind != ParRi: skip n
  elif name == "strip":
    skip n; e.emit("("); emitExpr(e, n); e.emit(").trim()")
    while n.kind != ParRi: skip n
  elif name == "repeat":
    skip n; e.emit("("); emitExpr(e, n); e.emit(").repeat("); emitExpr(e, n); e.emit(")")
    while n.kind != ParRi: skip n
  elif name == "split":
    skip n; e.emit("("); emitExpr(e, n); e.emit(").split("); emitExpr(e, n); e.emit(")")
    while n.kind != ParRi: skip n
  elif name == "contains" or name == "startsWith" or name == "endsWith":
    let jn = if name == "contains": "includes" else: name
    skip n; e.emit("("); emitExpr(e, n); e.emit(")." & jn & "("); emitExpr(e, n); e.emit(")")
    while n.kind != ParRi: skip n
  else:
    let boxed = boxLookup(name)                # ",i,j," of boxed param positions
    e.emit(mangle(callee)); inc n
    e.emit("(")
    var first = true
    var idx = 0
    while n.kind != ParRi:
      if not first: e.emit(", ")
      first = false
      if boxed.len > 0 and boxed.contains("," & $idx & ","):
        emitBoxArg(e, n)                       # pass the caller's lval by reference
      else:
        emitExpr(e, n)
      inc idx
    e.emit(")")
  consumeParRi n

proc emitRanges(e: var JsEmitter; rc: var Cursor) =
  ## (ranges V0 V1 (range lo hi) …) -> a JS `||`-chain of `_s === v` / range tests.
  ## The emitjs-specific value rendering; the branch structure is shared (hlwalk).
  if not (rc.kind == ParLe and rc.tagEnum == RangesTagId): return
  inc rc
  var f2 = true
  while rc.kind != ParRi:
    if not f2: e.emit(" || ")
    f2 = false
    if rc.kind == ParLe and rc.tagEnum == RangeTagId:
      inc rc
      e.emit("(_s >= " & exprToStr(rc) & " && _s <= " & exprToStr(rc) & ")")
      consumeParRi rc
    else:
      e.emit("(_s === " & exprToStr(rc) & ")")
  consumeParRi rc

proc emitCase(e: var JsEmitter; n: var Cursor; asExpr: bool) =
  ## (case SEL (of (ranges V…) BODY) … (else BODY)). Emitted as an if-chain over
  ## a once-bound selector; as an expression it's wrapped in an IIFE. Selector +
  ## branch structure via the shared hlwalk.decodeCase.
  var sel = default(Cursor)
  let branches = decodeCase(n, sel)
  var selc = sel
  # faithful: a 64-bit-int selector is a bigint but the `of` labels are numbers,
  # so `_s === 0` is always false — coerce the selector to Number for comparison.
  let selStr = if faithfulMode and producesBig(sel): "Number(" & exprToStr(selc) & ")"
               else: exprToStr(selc)
  if asExpr: e.emit("(function(_s){ ")
  else: e.emit("{ const _s = " & selStr & "; ")
  var first = true
  for br in branches:
    if br.isElse:
      e.emit(" else { ")
      var bc = br.body
      if asExpr: (e.emit("return "); emitExpr(e, bc); e.emit("; }"))
      else: (emitStmt(e, bc); e.emit(" }"))
    else:
      e.emit(if first: "if(" else: " else if(")
      first = false
      var rc = br.ranges
      emitRanges(e, rc)
      e.emit("){ ")
      var bc = br.body
      if asExpr: (e.emit("return "); emitExpr(e, bc); e.emit("; }"))
      else: (emitStmt(e, bc); e.emit(" }"))
  if asExpr: e.emit(" })(" & selStr & ")")
  else: e.emit(" }")

proc emitExpr(e: var JsEmitter; n: var Cursor; wantBig = false) =
  let bigSfx = if wantBig: "n" else: ""
  case n.kind
  of IntLit:  e.emit($pool.integers[n.intId] & bigSfx); inc n
  of UIntLit: e.emit($pool.uintegers[n.uintId] & bigSfx); inc n
  of FloatLit: e.emit($pool.floats[n.floatId]); inc n
  of CharLit: e.emit(jsString($n.charLit)); inc n
  of StringLit: e.emit(jsString(pool.strings[n.litId])); inc n
  of Symbol, SymbolDef, Ident:
    let nm = mangle(pool.syms[n.symId])
    let eo = enumLookup(nm)
    if eo.len > 0: e.emit(eo)                  # enum value -> its ordinal
    # A var/out param is a `{get v, set v}` box, and nimony does not always wrap a
    # use of one in `(hderef …)` — a `var seq[T]`/`var T` param reaches a magic like
    # `add` as a bare symbol. Emitting the box there yielded `s = __append(s, …)`,
    # i.e. `c.push is not a function`. The cell is the value; the box never is.
    elif boxContains(nm): e.emit(nm & ".v")
    else: e.emit(nm)
    inc n
  of ParLe:
    let t = n.tagEnum
    let bop = binOp(t)
    if bop.len > 0: emitBinop(e, n, bop, t)
    elif t == DivTagId:
      inc n
      let isFloat = n.kind == ParLe and n.tagEnum == FTagId
      let k = if faithfulMode and not isFloat: int64Kind(n) else: 0
      skip n
      if isFloat: (e.emit("("); emitExpr(e, n); e.emit(" / "); emitExpr(e, n); e.emit(")"))
      elif k > 0: (e.emit("_idiv("); emitExpr(e, n, true); e.emit(", "); emitExpr(e, n, true); e.emit(")"))
      else: (e.emit("(Math.trunc("); emitExpr(e, n); e.emit(" / "); emitExpr(e, n); e.emit("))"))
      consumeParRi n
    elif t == ModTagId:
      inc n
      let k = if faithfulMode: int64Kind(n) else: 0
      skip n
      if k > 0: (e.emit("_imod("); emitExpr(e, n, true); e.emit(", "); emitExpr(e, n, true); e.emit(")"))
      else: (e.emit("("); emitExpr(e, n); e.emit(" % "); emitExpr(e, n); e.emit(")"))
      consumeParRi n
    elif t == AndTagId:
      inc n; e.emit("("); emitExpr(e, n); e.emit(" && "); emitExpr(e, n); e.emit(")"); consumeParRi n
    elif t == OrTagId:
      inc n; e.emit("("); emitExpr(e, n); e.emit(" || "); emitExpr(e, n); e.emit(")"); consumeParRi n
    elif t == NotTagId:
      inc n; e.emit("(!"); emitExpr(e, n); e.emit(")"); consumeParRi n
    elif t == BitnotTagId:
      inc n
      # bitnot always carries a leading type child (i N)/(u N); skip it in both
      # modes (fast mode used to emit it as an expression and desync the cursor).
      var k = 0
      if n.kind == ParLe and (n.tagEnum == ITagId or n.tagEnum == UTagId):
        if faithfulMode: k = int64Kind(n)
        skip n
      if k > 0:
        let w = if k == 1: "_i64" else: "_u64"
        e.emit(w & "(~"); emitExpr(e, n, true); e.emit(")")
      else:
        e.emit("(~"); emitExpr(e, n); e.emit(")")
      consumeParRi n
    elif t == NegTagId:
      inc n
      let k = if faithfulMode: int64Kind(n) else: 0
      skip n
      if k > 0:
        let w = if k == 1: "_i64" else: "_u64"
        e.emit(w & "(-"); emitExpr(e, n, true); e.emit(")")
      else: (e.emit("(-"); emitExpr(e, n); e.emit(")"))
      consumeParRi n
    elif t == HderefTagId or t == HaddrTagId:
      inc n
      if (n.kind == Symbol or n.kind == SymbolDef or n.kind == Ident) and
         boxContains(mangle(pool.syms[n.symId])):
        e.emit(mangle(pool.syms[n.symId]) & ".v"); inc n   # boxed var-param cell
      else:
        emitExpr(e, n, wantBig)
      while n.kind != ParRi: skip n
      consumeParRi n
    elif t == ConvTagId or t == HconvTagId or t == DconvTagId:
      # `dconv` is the DISTINCT conversion, and it had no handler at all — it fell
      # through to the `undefined` fallback, which is how a `{.borrow.}`ed operator
      # (whose whole body is `result = (dconv T (add … (dconv (i 64) a) …))`)
      # came out as a function returning undefined. A distinct type IS its
      # underlying representation in JS, so it converts exactly like `conv`.
      inc n                                     # (conv TYPE VALUE) -> VALUE
      let targetK = if faithfulMode: int64Kind(n) else: 0
      let toInt = n.kind == ParLe and (n.tagEnum == ITagId or n.tagEnum == UTagId)
      let toChar = n.kind == ParLe and n.tagEnum == CTagId
      skip n                                    # target type; n now at source expr
      if targetK > 0:
        # narrower/number/float source -> bigint: BigInt() then width-wrap.
        let w = if targetK == 1: "_i64" else: "_u64"
        if n.kind == CharLit: (e.emit(w & "(BigInt(" & $int(n.charLit) & "))"); inc n)
        elif sourceIsChar(n): (e.emit(w & "(BigInt("); emitExpr(e, n); e.emit(".charCodeAt(0)))"))
        elif looksFloat(n): (e.emit(w & "(BigInt(Math.trunc("); emitExpr(e, n); e.emit(")))"))
        else: (e.emit(w & "(BigInt("); emitExpr(e, n); e.emit("))"))
      elif faithfulMode and producesBig(n):
        # 64-bit (bigint) source -> narrower int / number / float target.
        e.emit("Number("); emitExpr(e, n, true); e.emit(")")
      else:
        if toInt and n.kind == CharLit: (e.emit($int(n.charLit)); inc n)   # ord('A') -> 65
        elif toInt and sourceIsChar(n): (e.emit("("); emitExpr(e, n); e.emit(").charCodeAt(0)"))
        elif toInt: (e.emit("Math.trunc("); emitExpr(e, n); e.emit(")"))
        elif toChar and not sourceIsChar(n): (e.emit("String.fromCharCode("); emitExpr(e, n); e.emit(")"))
        else: emitExpr(e, n)
      while n.kind != ParRi: skip n
      consumeParRi n
    elif t == CastTagId:
      # (cast TYPE VALUE) — a ref/pointer cast is identity in JS; emit VALUE.
      inc n; skip n
      emitExpr(e, n, wantBig)
      while n.kind != ParRi: skip n
      consumeParRi n
    elif t == InstanceofTagId:
      # (instanceof VALUE TYPE) -> `VALUE instanceof Class` (exception dispatch).
      inc n
      emitExpr(e, n)
      e.emit(" instanceof ")
      let cls = excRefClassName(n)
      e.emit(if cls.len > 0: cls else: "Object")
      skip n
      while n.kind != ParRi: skip n
      consumeParRi n
    elif t == IfTagId:                          # if-EXPRESSION -> IIFE
      inc n
      e.emit("(function(){ ")
      var ifirst = true
      while n.kind != ParRi:
        if n.kind == ParLe and n.tagEnum == ElifTagId:
          inc n
          e.emit(if ifirst: "if(" else: " else if(")
          ifirst = false
          emitExpr(e, n); e.emit("){ return "); emitExpr(e, n); e.emit("; }")
          consumeParRi n
        elif n.kind == ParLe and n.tagEnum == ElseTagId:
          inc n; e.emit(" else { return "); emitExpr(e, n); e.emit("; }"); consumeParRi n
        else: skip n
      e.emit(" })()"); consumeParRi n
    elif t == SetconstrTagId:                   # set literal -> JS Set
      inc n; skip n                             # (set TYPE)
      e.emit("(function(){ const _s = new Set(); ")
      while n.kind != ParRi:
        if n.kind == ParLe and n.tagEnum == RangeTagId:
          inc n
          let isChar = n.kind == CharLit                # char range -> enumerate by code
          let lo = exprToStr(n); let hi = exprToStr(n)
          if isChar:
            e.emit("for(let _i=(" & lo & ").charCodeAt(0); _i<=(" & hi &
                   ").charCodeAt(0); _i++) _s.add(String.fromCharCode(_i)); ")
          else:
            e.emit("for(let _i=" & lo & "; _i<=" & hi & "; _i++) _s.add(_i); ")
          consumeParRi n
        else:
          e.emit("_s.add(" & exprToStr(n) & "); ")
      e.emit("return _s; })()"); consumeParRi n
    elif t == InsetTagId:                        # membership: (inset TYPE SET VALUE)
      inc n; skip n                             # set type
      # SET (inline setconstr -> OR-chain) then VALUE
      if n.kind == ParLe and n.tagEnum == SetconstrTagId:
        inc n; skip n
        var conds: seq[string] = @[]
        while n.kind != ParRi:
          if n.kind == ParLe and n.tagEnum == RangeTagId:
            inc n
            conds.add("(_v >= " & exprToStr(n) & " && _v <= " & exprToStr(n) & ")")
            consumeParRi n
          else:
            conds.add("(_v === " & exprToStr(n) & ")")
        consumeParRi n
        let body = if conds.len > 0: joinList(conds, " || ") else: "false"
        e.emit("(function(_v){ return " & body & "; })(" & exprToStr(n) & ")")
      else:
        let setExpr = exprToStr(n)
        e.emit("(" & setExpr & ".has(" & exprToStr(n) & "))")
      while n.kind != ParRi: skip n
      consumeParRi n
    elif t == CardTagId:                          # card(set) -> element count
      inc n; skip n                               # (card TYPE SET) -> SET.size
      if faithfulMode: e.emit("BigInt(")
      e.emit("("); emitExpr(e, n); e.emit(".size)")
      if faithfulMode: e.emit(")")
      while n.kind != ParRi: skip n
      consumeParRi n
    elif t == PlussetTagId or t == MinussetTagId or t == MulsetTagId or
         t == XorsetTagId:
      # (plusset/minusset/mulset/xorset TYPE A B) — set algebra over JS `Set`s.
      # union: keep A + all of B; difference: A minus B; intersection: A ∩ B;
      # symmetric difference: elements in exactly one. Each builds a fresh Set so
      # the operands are never mutated.
      inc n; skip n                               # set type
      let body =
        if t == PlussetTagId:
          "const _r = new Set(_a); for(const _x of _b) _r.add(_x); return _r;"
        elif t == MinussetTagId:
          "const _r = new Set(_a); for(const _x of _b) _r.delete(_x); return _r;"
        elif t == MulsetTagId:
          "const _r = new Set(); for(const _x of _a) if(_b.has(_x)) _r.add(_x); return _r;"
        else:
          "const _r = new Set(_a); for(const _x of _b){ if(_r.has(_x)) _r.delete(_x); else _r.add(_x); } return _r;"
      e.emit("(function(_a,_b){ " & body & " })(")
      emitExpr(e, n); e.emit(", "); emitExpr(e, n); e.emit(")")
      while n.kind != ParRi: skip n
      consumeParRi n
    elif t == SufTagId:
      inc n                                     # (suf LIT "suffix") -> LIT
      var big = wantBig
      if faithfulMode:
        var probe = n; skip probe
        if probe.kind == StringLit:
          let sfx = pool.strings[probe.litId]
          if sfx == "i64" or sfx == "u64": big = true
      emitExpr(e, n, big)
      while n.kind != ParRi: skip n
      consumeParRi n
    elif t == AconstrTagId:
      inc n                                     # (aconstr TYPE e0 e1 …) -> [e0,e1,…]
      # faithful: if the element type is a 64-bit int, emit bigint elements so a
      # later `s + xs[i]` (bigint arithmetic) doesn't mix bigint with number.
      var elemBig = false
      if faithfulMode and n.kind == ParLe and n.tagEnum == ArrayTagId:
        var tc = n; inc tc                      # (array ELEMTYPE lengthtype)
        elemBig = int64Kind(tc) > 0
      skip n                                    # type
      e.emit("[")
      var first = true
      while n.kind != ParRi:
        if not first: e.emit(", ")
        first = false
        emitExpr(e, n, elemBig)
      e.emit("]"); consumeParRi n
    elif t == PrefixTagId:
      inc n                                     # (prefix OP X) — @seq / $tostring
      let opsym = if n.kind == Symbol or n.kind == Ident: pool.syms[n.symId] else: ""
      let op = opName(opsym)
      inc n
      if op == "$" and opsym.len > 0 and not isMagicSym(opsym):
        # A USER `$` for this type. `String(x)` here quietly ignored it and
        # printed the underlying representation instead — and for a `{.borrow.}`d
        # distinct that is `undefined`. The `$` branch elsewhere in emitCall is
        # guarded by `magic`; this one was not.
        e.emit(mangle(opsym) & "("); emitExpr(e, n); e.emit(")")
      elif op == "$":
        if looksFloat(n): (e.emit("__sf("); emitExpr(e, n); e.emit(")"))
        else: (e.emit("String("); emitExpr(e, n); e.emit(")"))
      else: emitExpr(e, n)                      # `@` on an array literal -> the array
      while n.kind != ParRi: skip n
      consumeParRi n
    elif t == AtTagId or t == ArratTagId:
      inc n; e.emit("("); emitExpr(e, n); e.emit("["); emitIdx(e, n); e.emit("])")
      while n.kind != ParRi: skip n
      consumeParRi n
    elif t == ExprTagId:
      inc n; emitExpr(e, n, wantBig)            # (expr VALUE) -> VALUE
      while n.kind != ParRi: skip n
      consumeParRi n
    elif t == StmtsTagId:
      # a stmts block used as an expression. The one case aowljs produces this for
      # is a nested proc value (a closure): `(stmts (proc :anon …) SYMREF)` — a local
      # proc definition followed by a reference to it. Emit the proc as a JS arrow
      # function; lexical capture is free in JS, so the returned arrow closes over the
      # enclosing scope. The trailing self-reference is dropped.
      inc n
      var emitted = false
      while n.kind != ParRi:
        if not emitted and n.kind == ParLe and (n.tagEnum == ProcTagId or n.tagEnum == FuncTagId):
          emitArrow(e, n); emitted = true
        else:
          skip n
      if not emitted: e.emit("undefined")
      consumeParRi n
    elif t == OconstrTagId or t == NewobjTagId:
      # (oconstr TYPE (kv f v) …) — a plain object literal {f:v,…}. A `ref object`
      # sem's as (newobj TYPE (kv f v) …): under JS's GC the ref is just the object
      # reference, so it lowers to the identical literal. Inherited base fields are
      # already flattened into the kv list by sem. Omitted ref fields default to a
      # nil-conv (-> null), so every field carries its zero value.
      inc n
      # An exception type is a real JS class: `new Cls({fields})`. A plain
      # ref/value object stays an object literal `({fields})`.
      let cls = excRefClassName(n)
      let tkey = typeKeyOf(n)
      let isExc = cls.len > 0 and isExcClass(cls)
      skip n                                     # TYPE
      if isExc: e.emit("new " & cls & "(")
      e.emit("({")
      var first = true
      # `newobj` is the `ref object` construction. Marking it stops __cp from
      # deep-copying a reference — which would give every binding its own object
      # and quietly break identity, the exact opposite of the aliasing bug.
      if t == NewobjTagId:
        e.emit("__ref: 1")
        first = false
      # a type that participates in method dispatch carries its own name, because
      # a plain object literal has nothing else to dispatch on.
      if not isExc and tkey.len > 0 and dispatchesOn(tkey):
        if not first: e.emit(", ")      # a ref object carries BOTH markers
        e.emit("__t: " & jsString(tkey))
        first = false
      while n.kind != ParRi:
        if n.kind == ParLe and n.tagEnum == KvTagId:
          if not first: e.emit(", ")
          first = false
          inc n
          e.emit(mangle(pool.syms[n.symId]) & ": "); inc n
          emitExpr(e, n)
          while n.kind != ParRi: skip n         # trailing inheritance-depth marker
          consumeParRi n
        else: skip n
      e.emit("})")
      if isExc: e.emit(")")
      consumeParRi n
    elif t == DotTagId or t == DdotTagId:
      # (dot OBJ FIELD idx "name"); ddot is the ref-object deref-dot — the deref is
      # implicit in JS (objects are references), so both are just `OBJ.field`.
      inc n; emitExpr(e, n)
      e.emit("." & mangle(pool.syms[n.symId])); inc n
      while n.kind != ParRi: skip n
      consumeParRi n
    elif t == BaseobjTagId:
      # (baseobj TYPE depth VALUE) — an upcast to a base object. In JS an upcast is
      # identity (the same object reference), so emit just VALUE.
      inc n; skip n; skip n                     # TYPE, depth
      emitExpr(e, n)
      while n.kind != ParRi: skip n
      consumeParRi n
    elif t == TupconstrTagId:
      inc n; skip n                             # (tupconstr TYPE v… | (kv f v)…) -> [v…]
      e.emit("[")
      var first = true
      while n.kind != ParRi:
        if not first: e.emit(", ")
        first = false
        if n.kind == ParLe and n.tagEnum == KvTagId:
          inc n; skip n; emitExpr(e, n)
          while n.kind != ParRi: skip n
          consumeParRi n
        else: emitExpr(e, n)
      e.emit("]"); consumeParRi n
    elif t == TupatTagId:
      inc n; e.emit("("); emitExpr(e, n); e.emit("["); emitExpr(e, n); e.emit("])")
      while n.kind != ParRi: skip n
      consumeParRi n
    elif t == CaseTagId:
      emitCase(e, n, true)
    elif t == TrueTagId: (e.emit("true"); skip n)
    elif t == FalseTagId: (e.emit("false"); skip n)
    elif t == NilTagId: (e.emit("null"); skip n)
    elif isCallTag(t):
      emitCall(e, n)
    else:
      skip n; e.emit("undefined")   # TODO: sets/generics/var-params from aifjs-js
  else:
    inc n; e.emit("undefined")

proc collectParams(e: var JsEmitter; n: var Cursor): seq[string] =
  ## (params (param :x . . TYPE .) …) -> the mangled param names. The grammar
  ## navigation is the shared HL-IR skeleton (hlwalk.decodeParams); here we only
  ## mangle to JS names and mark var/out params for boxing.
  result = @[]
  inc n
  while n.kind != ParRi:
    if n.kind == ParLe and n.tagEnum == ParamTagId:
      inc n
      let pnm = mangle(pool.syms[n.symId]); inc n
      skip n                       # export
      skip n                       # pragmas
      var byRef = false
      if n.kind == ParLe and (n.tagEnum == MutTagId or n.tagEnum == OutTagId):
        byRef = true               # var/out param -> boxed
      let typeCur = n
      if faithfulMode and not byRef and int64Kind(n) > 0:
        bigAdd pnm
        curBigParams.add pnm
      case typeNamed(typeCur)
      of 1: charAdd pnm
      of 2: strAdd pnm
      else: discard
      if isSetType(typeCur): setAdd pnm        # HashSet param -> native JS Set
      if isFloatType(typeCur): floatAdd pnm    # float params -> echo/$ show .0
      # NOTE: a by-value param needs NO copy on entry. nimony rejects mutating one
      # ("cannot mutate expression p.x"), so the callee cannot write through it,
      # and it cannot hand it to a `var` param either. Copying every aggregate
      # argument at every call would have been O(n) per call for nothing. What
      # does need the copy is `var q = p` inside the body — a binding, handled
      # where bindings are.
      skip n                       # type
      while n.kind != ParRi: skip n
      consumeParRi n
      result.add pnm
      if byRef: curBoxed.add pnm
    else:
      skip n
  consumeParRi n

## true iff a routine node carries `(typevars …)`, i.e. it is the UNINSTANTIATED
## generic that nimony keeps in the .s.nif as a template for later instantiation.
## Its body is not runnable: it mentions type variables, and its calls are
## unresolved — the callee is `(at SYM TYPEARGS)` rather than a symbol, which no
## handler here consumes, so walking it desynchronised the cursor and aborted the
## whole emit with `consumeParRi: cursor not at ParRi`. Every instantiation is
## emitted separately under its own symbol, so dropping the template loses
## nothing; emitting it produced JS that could only have referenced `T`.
proc hasTypevars(c: Cursor): bool =
  var n = c
  if n.kind != ParLe: return false
  inc n                          # NAME export pragmas [typevars] params …
  var guard = 0
  while n.kind != ParRi and guard < 8:
    if n.kind == ParLe:
      if n.tagEnum == TypevarsTagId: return true
      if n.tagEnum == ParamsTagId: return false
    skip n
    inc guard
  return false

proc emitProc(e: var JsEmitter; n: var Cursor; isIter = false; isMethod = false) =
  ## (proc :name … (params …) RETTYPE … (stmts BODY)). Shape via hlwalk.decodeProc;
  ## params come before the body in the grammar, so collect (filling curBoxed)
  ## then emit — a forward decl (no stmts) emits nothing, as before.
  ## `isIter` marks an (iterator …) routine, emitted as a JS `function*` generator
  ## (its `(yld v)` bodies become `yield v`); a `for x in it(…)` then `for..of`s it.
  let isTemplate = hasTypevars(n)
  let sh = decodeProc(n)
  if isTemplate: return                  # decodeProc has consumed the node
  let rawName = pool.syms[sh.name]
  # ARC/RTTI hook instances (`=destroy`/`=wasmoved`/`=dup`/`=copy`/`=sinkh`/`=trace`)
  # are compiler-generated memory-management machinery, all named with a leading `=`.
  # JS is garbage-collected, so they're dead weight — drop them (decodeProc already
  # consumed the node). `=destroy` on an inheriting type sems as a `method`, which
  # emitStmt skips already; this catches the plain-proc hooks. User procs never begin
  # with `=`, so nothing user-defined is dropped.
  if rawName.len > 0 and rawName[0] == '=': return
  # a method's symbol is mapped to its DISPATCHER, so the overload itself has to
  # use the implementation name scanMethods reserved for it.
  var name = ""
  if isMethod: name = methImplFor(rawName)
  if name.len == 0: name = mangle(rawName)
  if isIter: iterNames.add name
  var params: seq[string] = @[]
  let savedBoxed = curBoxed
  curBoxed = @[]
  let savedBigParams = curBigParams
  curBigParams = @[]
  if sh.hasParams:
    var pc = sh.params
    params = collectParams(e, pc)              # also fills curBoxed
  # faithful: does this routine return a 64-bit int? (ret type follows params)
  let savedRetBig = curRetBig
  curRetBig = false
  if faithfulMode and sh.hasParams:
    var rc = sh.params
    skip rc                                    # past (params …)
    if rc.kind != ParRi and not (rc.kind == ParLe and rc.tagEnum == StmtsTagId):
      if int64Kind(rc) > 0: curRetBig = true
  if sh.hasBody:
    let kw = if isIter: "function* " else: "function "
    e.emit(kw & name & "(" & joinList(params, ", ") & "){\n")
    # coerce plain bigint params so an untyped-literal argument (a bare `number`)
    # can't mix with bigint arithmetic inside the body. BigInt() is a no-op on an
    # existing bigint, so typed callers are unaffected.
    for bp in curBigParams: e.emit("  " & bp & " = BigInt(" & bp & ");\n")
    # take ownership of by-value aggregates at entry, once, rather than at every
    # call site — a caller cannot know whether the callee writes to them.
    var bc = sh.body
    emitStmts(e, bc)
    e.emit("\n}\n")
  curRetBig = savedRetBig
  curBoxed = savedBoxed
  curBigParams = savedBigParams

proc emitArrow(e: var JsEmitter; n: var Cursor) =
  ## Emit an anonymous/nested (proc …) as a JS arrow function value:
  ##   (x) => { <body> }
  ## Used for closures — the arrow captures the enclosing scope lexically, so a
  ## `proc(x): int = x + n` returned from `makeAdder(n)` becomes `(x) => { … }`
  ## that closes over `n`. A `(proctype …)` value needs no JS type annotation.
  let sh = decodeProc(n)
  var params: seq[string] = @[]
  let savedBoxed = curBoxed
  curBoxed = @[]
  let savedBigParams = curBigParams
  curBigParams = @[]
  if sh.hasParams:
    var pc = sh.params
    params = collectParams(e, pc)
  let savedRetBig = curRetBig
  curRetBig = false
  if faithfulMode and sh.hasParams:
    var rc = sh.params
    skip rc
    if rc.kind != ParRi and not (rc.kind == ParLe and rc.tagEnum == StmtsTagId):
      if int64Kind(rc) > 0: curRetBig = true
  e.emit("(" & joinList(params, ", ") & ") => {\n")
  for bp in curBigParams: e.emit("  " & bp & " = BigInt(" & bp & ");\n")
  if sh.hasBody:
    var bc = sh.body
    emitStmts(e, bc)
  e.emit("\n}")
  curRetBig = savedRetBig
  curBoxed = savedBoxed
  curBigParams = savedBigParams

proc emitLocal(e: var JsEmitter; n: var Cursor) =
  ## (var/let/const/result NAME EXPORT PRAGMAS TYPE VALUE) — fixed positional
  ## shape (like interp's execLocal): after the name come export, pragmas, type,
  ## then the initializer (a `.` dot if none).
  let sh = decodeLocal(n)
  let nm = mangle(pool.syms[sh.name])
  let big = faithfulMode and int64Kind(sh.typ) > 0
  if big: bigAdd nm
  let isSet = isSetType(sh.typ)               # HashSet -> native JS Set
  if isSet: setAdd nm
  let tn = typeNamed(sh.typ)                  # distinguish char (charCodeAt) from string
  if tn == 1: charAdd nm
  elif tn == 2:
    var isCh = false
    if sh.hasInit:
      var ic = sh.init
      if ic.kind == CharLit: isCh = true
    if isCh: charAdd nm else: strAdd nm
  block:                                        # track float vars (echo/$ must show .0)
    var isF = isFloatType(sh.typ)
    if not isF and sh.hasInit:
      var ic = sh.init
      if ic.kind == FloatLit: isF = true
    if isF: floatAdd nm
  block:                                        # track a tuple var's float element slots
    let fis = tupleFloatIndices(sh.typ)
    if fis.len > 0:
      tupleVars.add nm
      tupleFloatIdx.add fis
  e.emit("let " & nm)
  if sh.hasInit:
    var ic = sh.init
    # A local declared `int`/`int64` is registered as a bigint on the strength of
    # its TYPE, but its initializer can still be a plain `number` (a tuple slot, a
    # field, a call result) — and then every later use is a lie that surfaces far
    # away as "Cannot convert 3 to a BigInt". Coerce at the binding.
    e.emit(" = ")
    # `var b = a` over a value type has to copy; a constructor or a computed
    # value is already fresh, so only an LVALUE needs it.
    let cp = not big and copyNeeded(sh.typ) and isLvalueExpr(ic)
    if cp: e.emit("__cp(")
    if big: emitBigOperand(e, ic) else: emitExpr(e, ic, big)
    if cp: e.emit(")")
  elif big:
    e.emit(" = 0n")
  else:
    e.emit(" = " & defaultVal(sh.typ))     # uninitialised — T's own default
  e.emit(";")

proc emitAsgn(e: var JsEmitter; n: var Cursor) =
  inc n
  if isExcThreadvar(n):
    # nimony threads a raise through the `exc` global: `exc = <newobj>` right
    # before `(raise …)`. Stash the constructed exception so the raise throws it;
    # `exc = nil` / `exc = err` bookkeeping is dropped (JS uses the catch binding).
    skip n                                       # LHS (the exc threadvar)
    if n.kind == ParLe and (n.tagEnum == CastTagId or n.tagEnum == NewobjTagId or
                            n.tagEnum == OconstrTagId):
      var tmp = JsEmitter(js: "")
      var rhs = n
      emitExpr(tmp, rhs)
      pendingThrow = tmp.js
    skip n                                        # RHS
    consumeParRi n
    return
  # if the lvalue is a known bigint local, a bare-literal RHS must be bigint too.
  var lhsBig = false
  if faithfulMode and (n.kind == Symbol or n.kind == SymbolDef or n.kind == Ident):
    lhsBig = bigContains(mangle(pool.syms[n.symId]))
  emitExpr(e, n); e.emit(" = ")
  # An assignment from an lvalue is a copy for a value type. The LHS's declared
  # type is not in reach here, so this leans on the RHS being an lvalue plus
  # `__cp` being the identity on scalars, strings and `ref`s.
  let cpRhs = not lhsBig and isLvalueExpr(n)
  if cpRhs: e.emit("__cp(")
  if lhsBig: emitBigOperand(e, n) else: emitExpr(e, n, lhsBig)
  if cpRhs: e.emit(")")
  e.emit(";")
  consumeParRi n

proc emitIf(e: var JsEmitter; n: var Cursor) =
  var first = true
  for br in decodeIf(n):
    if br.isElse:
      var bc = br.body
      e.emit(" else {\n"); emitStmt(e, bc); e.emit("\n}")
    else:
      var cc = br.cond
      e.emit(if first: "if(" else: " else if(")
      emitExpr(e, cc); e.emit("){\n")
      var bc = br.body
      emitStmt(e, bc); e.emit("\n}")
      first = false

proc emitWhile(e: var JsEmitter; n: var Cursor) =
  inc n
  e.emit("while("); emitExpr(e, n); e.emit("){\n"); emitStmt(e, n); e.emit("\n}")
  consumeParRi n

proc emitRet(e: var JsEmitter; n: var Cursor) =
  inc n
  if n.kind == ParRi: e.emit("return;")
  else:
    e.emit("return "); emitExpr(e, n, curRetBig); e.emit(";")
  consumeParRi n

proc exprToStr(n: var Cursor; wantBig = false): string =
  ## emit one expression into a fresh buffer (for building loop headers).
  var tmp = JsEmitter(js: "")
  emitExpr(tmp, n, wantBig)
  result = tmp.js

proc collExpr(n: var Cursor): string =
  ## dig a for-iterable down to its collection: nimony lowers `for x in xs` to
  ## `items(toOpenArray(xs))` wrapped in hderef; unwrap to `xs`.
  if n.kind == ParLe:
    let t = n.tagEnum
    if t == HderefTagId or t == HaddrTagId:
      inc n
      result = collExpr(n)
      while n.kind != ParRi: skip n
      consumeParRi n
      return
    if t == CallTagId or t == HcallTagId:
      # inspect the callee via a probe so an unmatched call keeps `n` at the `(call`
      # for the exprToStr fallthrough below (a bare iterator call, e.g. `evens(10)`,
      # must be emitted whole as the for..of iterable — not unwrapped).
      var probe = n; inc probe
      let callee = if probe.kind == Symbol or probe.kind == SymbolDef: pool.syms[probe.symId] else: ""
      let name = opName(callee)
      if name == "items" or name == "mitems" or name == "pairs" or name == "toOpenArray":
        inc n; inc n                 # past the `(call` and its callee -> the collection
        result = collExpr(n)
        while n.kind != ParRi: skip n
        consumeParRi n
        return
  result = exprToStr(n)

proc emitFor(e: var JsEmitter; n: var Cursor) =
  ## (for ITER (unpackflat (let :v …)…) BODY) — range | countdown | collection,
  ## with 1 loop var (`for x in`) or 2 (`for i, x in`).
  inc n
  var kind = 0                  # 0=collection, 1=range, 2=countdown
  var a = "0"                   # range lo / countdown from
  var b = "0"                   # range hi / countdown to
  var cmp = " < "
  var step = "1"
  var coll = ""
  var fromIter = false          # the iterable is a user `iterator` (a generator)
  if n.kind == ParLe and n.tagEnum == InfixTagId:
    inc n
    let op = opName(if n.kind == Symbol or n.kind == Ident: pool.syms[n.symId] else: "")
    inc n
    a = exprToStr(n); b = exprToStr(n); consumeParRi n
    if op == "..<": (cmp = " < "; kind = 1)
    elif op == "..": (cmp = " <= "; kind = 1)
    else: coll = "[]"
  else:
    var isCd = false
    if n.kind == ParLe and (n.tagEnum == CallTagId or n.tagEnum == HcallTagId):
      var probe = n; inc probe
      let cn = opName(if probe.kind == Symbol or probe.kind == SymbolDef: pool.syms[probe.symId] else: "")
      if cn == "countdown": isCd = true
    if isCd:
      inc n; skip n             # past call, callee
      a = exprToStr(n); b = exprToStr(n)
      if n.kind != ParRi: step = exprToStr(n)
      while n.kind != ParRi: skip n
      consumeParRi n
      kind = 2
    else:
      fromIter = isIterCall(n)
      coll = collExpr(n)
  # loop variables (1 or 2), from (unpackflat (let :v …)…)
  var vars: seq[string] = @[]
  var loopBig = false                 # counter is a 64-bit int -> bigint (faithful)
  if n.kind == ParLe and n.tagEnum == UnpackflatTagId:
    inc n
    var firstVar = true
    while n.kind != ParRi:
      if n.kind == ParLe and (n.tagEnum == LetTagId or n.tagEnum == VarTagId):
        inc n
        let vnm = mangle(pool.syms[n.symId])
        vars.add vnm; inc n
        skip n                         # export
        skip n                         # pragmas
        if firstVar and faithfulMode and int64Kind(n) > 0:
          loopBig = true
          bigAdd vnm
        firstVar = false
        while n.kind != ParRi: skip n  # type, value
        consumeParRi n
      else: skip n
    consumeParRi n
  else:
    skip n
  let v0 = if vars.len > 0: vars[0] else: "v__i"
  # counter loops over bigint bounds: wrap the endpoints so `i`, the comparison and
  # `i++` / `i -= step` all stay bigint (BigInt() is a no-op on an existing bigint).
  let la = if loopBig: "BigInt(" & a & ")" else: a
  let lb = if loopBig: "BigInt(" & b & ")" else: b
  let lstep = if loopBig: "BigInt(" & step & ")" else: step
  if kind == 1:
    e.emit("for(let " & v0 & " = " & la & "; " & v0 & cmp & lb & "; " & v0 & "++){\n")
    emitStmt(e, n); e.emit("\n}")
  elif kind == 2:
    e.emit("for(let " & v0 & " = " & la & "; " & v0 & " >= " & lb & "; " & v0 & " -= " & lstep & "){\n")
    emitStmt(e, n); e.emit("\n}")
  elif vars.len >= 2 and fromIter:
    # `for i, v in myIter(…)` — a generator yielding a TUPLE. The two loop vars
    # are that tuple's elements, not (index, element): indexing a generator gave
    # `_c.length` = undefined and the loop body never ran at all.
    e.emit("for(let [" & vars[0] & ", " & vars[1] & "] of " & coll & "){\n")
    if loopBig: e.emit(vars[0] & " = BigInt(" & vars[0] & ");\n")
    emitStmt(e, n); e.emit("\n}")
  elif vars.len >= 2:           # for i, x in coll -> indexed
    # faithful: a 64-bit index var is a bigint, but `_c.length` and the JS index
    # slot are `number` — start at 0n, compare against BigInt(length), coerce the
    # element read with Number(i).
    let i0 = if loopBig: "0n" else: "0"
    let len = if loopBig: "BigInt(_c.length)" else: "_c.length"
    let idxRead = if loopBig: "Number(" & vars[0] & ")" else: vars[0]
    e.emit("{ const _c = " & coll & "; for(let " & vars[0] & " = " & i0 & "; " & vars[0] &
           " < " & len & "; " & vars[0] & "++){ const " & vars[1] & " = _c[" & idxRead & "];\n")
    emitStmt(e, n); e.emit("\n} }")
  else:
    e.emit("for(const " & v0 & " of " & coll & "){\n")
    emitStmt(e, n); e.emit("\n}")
  consumeParRi n

proc emitTry(e: var JsEmitter; n: var Cursor) =
  ## (try BODY (except …)… (fin STMTS)?) — the lowering nimony emits for `defer`
  ## (a bare `try … (fin …)`) and for `try/except/finally`. Maps to JS
  ## `try { BODY } catch(_ex){ … } finally { … }`. The `fin` clause runs on every
  ## exit path (including a `return` inside BODY), matching nimony `defer`/finally.
  inc n
  e.emit("try {\n")
  emitStmt(e, n)                       # the protected body (a stmts block)
  e.emit("\n}")
  while n.kind != ParRi:
    if n.kind == ParLe and n.tagEnum == ExceptTagId:
      # (except . BODY) — nimony has already lowered `except T as e / except:` into
      # an `if (instanceof err T) …` cascade inside BODY, threaded through the `exc`
      # global and an `err` alias. JS has one dynamic catch binding, so: name the
      # catch after that `err` alias (the `(let :err … exc)` is then redundant and
      # dropped), and let the cascade's `instanceof`/`cursor`/re-raise fall out of
      # the generic emit (see emitExpr/InstanceofTagId, CursorTagId, RaiseTagId).
      inc n                                       # past 'except'
      if n.kind == DotToken: inc n                # catch-all filter `.`
      elif n.kind != ParRi: skip n                # explicit type filter (unused in JS)
      var catchVar = "_ex"
      block:                                      # probe BODY for `(let :err … exc)`
        var probe = n
        if probe.kind == ParLe and probe.tagEnum == StmtsTagId:
          inc probe
          while probe.kind != ParRi:
            if probe.kind == ParLe and probe.tagEnum == LetTagId:
              inc probe
              catchVar = mangle(pool.syms[probe.symId])
              break
            else: skip probe
      e.emit(" catch(" & catchVar & ") {\n")
      let savedCatch = curCatchVar
      curCatchVar = catchVar
      if n.kind == ParLe and n.tagEnum == StmtsTagId:
        inc n
        while n.kind != ParRi:
          if n.kind == ParLe and n.tagEnum == LetTagId: skip n   # drop `let err = exc`
          else: emitStmt(e, n)
        consumeParRi n
      else:
        while n.kind != ParRi:
          if n.kind == ParLe and n.tagEnum == StmtsTagId: emitStmt(e, n)
          else: skip n
      curCatchVar = savedCatch
      e.emit("\n}")
      consumeParRi n
    elif n.kind == ParLe and n.tagEnum == FinTagId:
      inc n
      e.emit(" finally {\n")
      emitStmt(e, n)
      e.emit("\n}")
      while n.kind != ParRi: skip n
      consumeParRi n
    else:
      skip n
  consumeParRi n

proc emitType(e: var JsEmitter; n: var Cursor) =
  ## Most type decls vanish (JS is untyped). An exception type, though, must be a
  ## real class so `new T(…)` / `x instanceof T` work — emit it as one. Base fields
  ## are flattened into every `newobj`, so the constructor just copies the field bag.
  var c = n
  inc c
  if c.kind == Symbol or c.kind == SymbolDef or c.kind == Ident:
    let nm = mangle(pool.syms[c.symId])
    if isExcClass(nm):
      e.emit("class " & nm & " extends " & excParent(nm) &
             " { constructor(f){ super(); if(f) Object.assign(this, f); } }\n")
  skip n

proc emitStmt(e: var JsEmitter; n: var Cursor) =
  if n.kind != ParLe:
    inc n
    return
  let t = n.tagEnum
  if t == StmtsTagId: emitStmts(e, n)
  elif t == TryTagId: emitTry(e, n)
  elif t == TypeTagId: emitType(e, n)
  elif t == VarTagId or t == LetTagId or t == ConstTagId or t == GvarTagId or
       t == GletTagId or t == ResultTagId or t == CursorTagId: emitLocal(e, n)
  elif t == RaiseTagId:
    inc n
    if n.kind == DotToken:                        # `(raise .)` -> re-raise
      e.emit("throw " & (if curCatchVar.len > 0: curCatchVar else: "new Error()") & ";")
      inc n
    elif pendingThrow.len > 0:                    # a stashed `exc = newobj`
      e.emit("throw " & pendingThrow & ";"); pendingThrow = ""
      skip n
    else:                                         # bare `raise ErrorCode`
      var nm = ""
      if n.kind == Symbol or n.kind == SymbolDef or n.kind == Ident:
        nm = opName(pool.syms[n.symId])
      e.emit("throw new Error(" & jsString(nm) & ");")
      skip n
    consumeParRi n
  elif t == AsgnTagId: emitAsgn(e, n)
  elif t == IfTagId: emitIf(e, n)
  elif t == WhileTagId: emitWhile(e, n)
  elif t == RetTagId: emitRet(e, n)
  elif t == CaseTagId: emitCase(e, n, false)
  elif t == ForTagId: emitFor(e, n)
  elif t == BreakTagId: (e.emit("break;"); skip n)
  elif t == ContinueTagId: (e.emit("continue;"); skip n)
  elif isCallTag(t): (emitCall(e, n); e.emit(";"))
  elif t == ProcTagId or t == FuncTagId: emitProc(e, n)
  elif t == IteratorTagId: emitProc(e, n, isIter = true)
  elif t == MethodTagId: emitProc(e, n, isMethod = true)
  elif t == YldTagId:
    inc n                                       # (yld VALUE) -> yield VALUE;
    e.emit("yield "); emitExpr(e, n, curRetBig); e.emit(";")
    consumeParRi n
  else: skip n

proc scanExcTypes(n: var Cursor) =
  ## walk the tree; record every object type transitively inheriting `Exception`
  ## (base is `Exception…`, or another already-recorded exception object type) so
  ## it is later emitted as a real JS class. Base types precede derived ones in the
  ## decl order nimony emits, so a single forward pass resolves the chain.
  if n.kind != ParLe:
    inc n
    return
  if n.tagEnum == TypeTagId:
    var c = n
    inc c                                # NAME
    let nm = if c.kind == Symbol or c.kind == SymbolDef or c.kind == Ident:
               mangle(pool.syms[c.symId]) else: ""
    let key = if c.kind == Symbol or c.kind == SymbolDef or c.kind == Ident:
                prettyBase(pool.syms[c.symId]) else: ""
    inc c                                # past NAME -> export/typevars/pragmas…
    while c.kind != ParRi and not (c.kind == ParLe and c.tagEnum == ObjectTagId):
      skip c                             # skip export, typevars, pragmas to the body
    if nm.len > 0 and c.kind == ParLe and c.tagEnum == ObjectTagId:
      inc c                              # -> BASE: a symbol, `(ref X.Obj …)`, or `.`
      objTypeNames.add key
      objTypeBases.add typeKeyOf(c)
      if c.kind == Symbol or c.kind == SymbolDef or c.kind == Ident:
        let baseNm = pool.syms[c.symId]
        if opName(baseNm) == "Exception":
          excClassNames.add nm; excClassBase.add "Error"
        elif isExcClass(mangle(baseNm)):
          excClassNames.add nm; excClassBase.add mangle(baseNm)
    skip n
  else:
    inc n
    while n.kind != ParRi: scanExcTypes(n)
    consumeParRi n

proc scanMethods(n: var Cursor) =
  ## walk the tree; for every `(method :sym … (params (param :self … TYPE …) …) …)`
  ## allocate the group's dispatcher (one per method BASE name), the overload's own
  ## implementation name, and its receiver type. Must run before anything mangles a
  ## method symbol: it seeds the rename table so a call site that sem resolved to
  ## *any* overload emits the dispatcher's name instead.
  if n.kind != ParLe:
    inc n
    return
  if n.tagEnum == MethodTagId:
    var c = n
    let sh = decodeProc(c)
    let raw = pool.syms[sh.name]
    if raw.len > 0 and raw[0] != '=':          # skip the ARC hooks (=destroy & co)
      let key = opName(raw)
      var di = -1
      for i in 0 ..< methDispKey.len:
        if methDispKey[i] == key: di = i
      if di < 0:
        methDispKey.add key
        methDispName.add uniqueJs(key)
        di = methDispKey.len - 1
      let disp = methDispName[di]
      renameKeys.add raw
      renameVals.add disp
      var recv = ""
      if sh.hasParams:
        var pc = sh.params
        inc pc                                 # into (params …)
        if pc.kind == ParLe and pc.tagEnum == ParamTagId:
          inc pc                               # `param` tag
          inc pc                               # name
          skip pc                              # export
          skip pc                              # pragmas
          recv = typeKeyOf(pc)
      methImplSym.add raw
      methImplName.add uniqueJs(key & "__" & recv)
      methImplDisp.add disp
      methImplType.add recv
    skip n
  else:
    inc n
    while n.kind != ParRi: scanMethods(n)
    consumeParRi n

proc emitDispatchers(): string =
  ## `_base` (declared in the prelude, shared across modules) plus one dispatcher
  ## per method name. Tables accumulate across modules and function declarations
  ## hoist, so re-emitting per module is harmless — the last, most complete
  ## definition is the one that binds.
  if methDispName.len == 0: return ""
  var e = JsEmitter(js: "")
  var pairs = ""
  var first = true
  for i in 0 ..< objTypeNames.len:
    if objTypeBases[i].len > 0 and dispatchesOn(objTypeNames[i]):
      if not first: pairs.add ", "
      first = false
      pairs.add jsString(objTypeNames[i]) & ": " & jsString(objTypeBases[i])
  if pairs.len > 0: e.emit("Object.assign(_base, {" & pairs & "});\n")
  for d in 0 ..< methDispName.len:
    let disp = methDispName[d]
    e.emit("function " & disp & "(_s){\n")
    e.emit("  let _t = (_s === null || _s === undefined) ? \"\" : (_s.__t || \"\");\n")
    e.emit("  while(_t !== \"\"){\n")
    for i in 0 ..< methImplSym.len:
      if methImplDisp[i] == disp:
        e.emit("    if(_t === " & jsString(methImplType[i]) & ") return " &
               methImplName[i] & ".apply(null, arguments);\n")
    e.emit("    _t = _base[_t] || \"\";\n")
    e.emit("  }\n")
    # no tag, or nothing overrides anywhere up the chain: the `{.base.}` method,
    # which is the first overload declared for this name.
    var fb = ""
    for i in 0 ..< methImplSym.len:
      if methImplDisp[i] == disp and fb.len == 0: fb = methImplName[i]
    if fb.len > 0: e.emit("  return " & fb & ".apply(null, arguments);\n")
    e.emit("}\n")
  result = e.js

proc scanEnums(n: var Cursor) =
  ## walk the tree; for (enum … (efld :val … (tup ORD "name"))) record val->ORD.
  if n.kind != ParLe:
    inc n
    return
  if n.tagEnum == EnumTagId:
    inc n
    while n.kind != ParRi:
      if n.kind == ParLe and n.tagEnum == EfldTagId:
        inc n
        let valName = mangle(pool.syms[n.symId]); inc n
        while n.kind != ParRi:
          if n.kind == ParLe and n.tagEnum == TupTagId:
            inc n
            if n.kind == IntLit: (enumKeys.add valName; enumVals.add $pool.integers[n.intId])
            while n.kind != ParRi: skip n
            consumeParRi n
          else: skip n
        consumeParRi n
      else: skip n
    consumeParRi n
  else:
    inc n
    while n.kind != ParRi: scanEnums(n)
    consumeParRi n

proc scanProcBoxed(n: var Cursor) =
  ## walk the tree; for each (proc/func :name … (params …)) record which param
  ## positions are var/out, so call sites know which args to box.
  if n.kind != ParLe:
    inc n
    return
  if n.tagEnum == ProcTagId or n.tagEnum == FuncTagId or n.tagEnum == IteratorTagId:
    inc n
    let pname = opName(pool.syms[n.symId]); inc n
    var idxs: seq[int] = @[]
    while n.kind != ParRi:
      if n.kind == ParLe and n.tagEnum == ParamsTagId:
        inc n
        var i = 0
        while n.kind != ParRi:
          if n.kind == ParLe and n.tagEnum == ParamTagId:
            inc n
            skip n            # param symbol
            skip n; skip n    # export, pragmas
            if n.kind == ParLe and (n.tagEnum == MutTagId or n.tagEnum == OutTagId):
              idxs.add i
            while n.kind != ParRi: skip n
            consumeParRi n
            inc i
          else: skip n
        consumeParRi n
      else: skip n
    if idxs.len > 0:
      var s = ","
      for bi in idxs: s.add $bi & ","
      boxProcNames.add pname
      boxProcIdx.add s
    consumeParRi n
  else:
    inc n
    while n.kind != ParRi: scanProcBoxed(n)
    consumeParRi n

proc jsPrelude*(): string =
  ## the once-per-program runtime shim (echo capture, float print, seq/str append,
  ## and — in faithful mode — the 64-bit bigint wrappers).
  var e = JsEmitter(js: "")
  e.emit("'use strict';\nlet __out='';\nconst _base = {};\n")
  e.emit("function __w(x){ __out += (x===true?'true':x===false?'false':String(x)); }\n")
  # `String(x)` is NOT nimony's `$float`. Both print shortest-round-trip digits,
  # but they disagree about when to use exponent form: JS switches at 1e21 and
  # 1e-7, nimony at 1e17 and 1e-8. So 1e17 came out "100000000000000000.0" (want
  # "1e+17") and 1e-7 came out "1e-7" (want "0.0000001"). `Number.isInteger` also
  # loses the sign of -0.0 and appended ".0" to an exponent ("1e+21.0").
  # toExponential() with no argument gives exactly the shortest digits plus the
  # decimal exponent, so the placement below is a re-layout, never a re-rounding.
  e.emit("function __fs(x){\n" &
         "  if (x !== x) return 'nan';\n" &
         "  if (x === Infinity) return 'inf';\n" &
         "  if (x === -Infinity) return '-inf';\n" &
         "  if (x === 0) return Object.is(x, -0) ? '-0.0' : '0.0';\n" &
         "  const ex = x.toExponential(), at = ex.indexOf('e');\n" &
         "  const k = parseInt(ex.slice(at + 1), 10);\n" &
         "  if (k < -7 || k > 16) return ex;\n" &
         "  const mant = ex.slice(0, at), neg = mant[0] === '-';\n" &
         "  const d = (neg ? mant.slice(1) : mant).replace('.', '');\n" &
         "  let out;\n" &
         "  if (k >= 0) out = d.length <= k + 1 ? d + '0'.repeat(k + 1 - d.length) + '.0'\n" &
         "                                      : d.slice(0, k + 1) + '.' + d.slice(k + 1);\n" &
         "  else out = '0.' + '0'.repeat(-k - 1) + d;\n" &
         "  return (neg ? '-' : '') + out;\n" &
         "}\n")
  e.emit("function __wf(x){ __out += __fs(x); }\n")
  e.emit("function __sf(x){ return __fs(x); }\n")
  # Copy-on-assign. A nimony object/tuple/array/seq/set is a VALUE: `var b = a`
  # then `b.x = 1` must not be visible through `a`. JS shares the reference, so
  # every one of those assignments was silently aliasing. `__ref` marks an object
  # built by `newobj` — a `ref object`, which has reference semantics and must be
  # shared, not copied — and is what lets one structural copier serve both.
  e.emit("function __cp(v){\n" &
         "  if (v === null || typeof v !== 'object' || v.__ref) return v;\n" &
         "  if (Array.isArray(v)) { const r = new Array(v.length);\n" &
         "    for (let i = 0; i < v.length; i++) r[i] = __cp(v[i]); return r; }\n" &
         "  if (v instanceof Set) return new Set(v);\n" &
         "  if (v instanceof Map) return new Map(v);\n" &
         "  const o = {}; for (const k in v) o[k] = __cp(v[k]); return o;\n" &
         "}\n")
  if faithfulMode:
    # faithful: a bare int literal argument is a `number`, but the seq may hold
    # `bigint` elements — coerce so a later `sum + xs[i]` doesn't mix the two.
    e.emit("function __append(c, x){ if(typeof c === 'string') return c + x; " &
           "if(typeof x === 'number' && c.length > 0 && typeof c[0] === 'bigint') x = BigInt(x); " &
           "c.push(x); return c; }\n")
  else:
    e.emit("function __append(c, x){ if(typeof c === 'string') return c + x; c.push(x); return c; }\n")
  if faithfulMode:
    # faithful-export runtime: 64-bit ints are JS `bigint`; wrap arithmetic to the
    # exact two's-complement width and guard integer division. (echo prints a bigint
    # via String(x), i.e. "5" not "5n", so no writer change is needed.)
    e.emit("const _i64 = (x) => BigInt.asIntN(64, x);\n")
    e.emit("const _u64 = (x) => BigInt.asUintN(64, x);\n")
    e.emit("const _idiv = (a, b) => { if (b === 0n) throw new Error(\"DivByZero\"); return a / b; };\n")
    e.emit("const _imod = (a, b) => { if (b === 0n) throw new Error(\"DivByZero\"); return a % b; };\n")
  result = e.js

proc jsFlush*(): string =
  ## return the captured output once, at the end. (`return` at module top level is
  ## legal — Node wraps every module file in a function.)
  result = "\nreturn __out;\n"

proc emitModuleBody*(root: var Cursor): string =
  ## emit ONE module's JS (no prelude/flush): procs float up (JS hoists function
  ## decls), top-level statements run at module scope. Enum-ordinal and var/out
  ## param scans accumulate into the shared tables so cross-module calls resolve.
  var scanCur0 = root
  scanMethods(scanCur0)               # first: it seeds the rename table
  var scanCur = root
  scanEnums(scanCur)
  var scanCur2 = root
  scanProcBoxed(scanCur2)
  var scanCur3 = root
  scanExcTypes(scanCur3)
  var e = JsEmitter(js: "")
  emitStmt(e, root)
  result = emitDispatchers() & e.js

proc emitModule*(root: var Cursor): string =
  ## single-module convenience: full standalone JS (prelude + body + flush).
  result = jsPrelude() & emitModuleBody(root) & jsFlush()
