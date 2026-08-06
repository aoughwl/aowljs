## abisize.nim — answer `sizeof(T)` for an AGGREGATE, by mapping the NIF type
## onto an `aowlabi` `TypeDesc` and asking the one layout engine.
##
## WHY THIS EXISTS. `sizeof` of a non-scalar was the single language FEATURE
## aowljs reported as unsupported across the whole corpus, and the reason given
## was "an aggregate needs a real layout model". That model exists — it is
## [aowlabi](https://github.com/aoughwl/aowlabi), which is gated against nimony's
## own `sizeof` (122/122), against gcc on the struct aowlc prints, and against
## gcc `-m32`. What was missing was never the math; it was the mapping from a NIF
## type node to a `TypeDesc`. That mapping is this file, and it is the whole of
## it: nothing here computes a size.
##
## The alternative — extending `emitjs`'s `scalarSizeOf` table upward — would
## have made this backend the THIRD implementation of C struct layout in the
## stack (nimony's `sizeof.nim`, aowlabi, here), which is precisely the shape
## that lets a defect live in two of them and be fixed in one. A mapper can be
## wrong; it cannot be *independently* wrong about padding.
##
## WHAT IT DOES NOT ANSWER. `abiSizeOf` returns -1 rather than guessing, and
## every caller must treat -1 as "report the gap", never as a size. Unmapped
## cases: a type symbol declared in a module aowljs does not replay (std/system's
## own types, which reach this by NAME instead), and any tag not listed below.
## -1 is the fail-CLOSED answer: a wrong size is silent, a reported gap is not.

when defined(nimony):
  {.feature: "lenientnils".}

import nifcursors, nifstreams, nimony_model
import tags
import aowlabi

# ---------------------------------------------------------------------------
# the type table
# ---------------------------------------------------------------------------
# Descriptors are built EAGERLY at scan time, not lazily from a stored Cursor:
# nimony emits a type's declaration before any use of it, and a cursor into a
# module tree is only valid while that module's buffer is alive — aowljs frees
# each module's buffer after emitting it. Eager building sidesteps the lifetime
# question entirely, and the declaration order makes it correct.
#
# Parallel seqs rather than a Table, matching emitjs: nimony's `Table.[]=` is
# `.raises`, and nothing here may raise.

var tdKeys: seq[string] = @[]
var tdVals: seq[TypeDesc] = @[]

proc tdLookup(sym: string): TypeDesc =
  for i in 0 ..< tdKeys.len:
    if tdKeys[i] == sym: return tdVals[i]
  return TypeDesc(nil)

## The readable base of a nimony symbol: `Mixed.0.` -> `Mixed`,
## `RootObj.0.sysvq0asl` -> `RootObj`.
proc baseNameOf(sym: string): string =
  var r = ""
  var i = 0
  while i < sym.len and sym[i] != '.':
    r.add sym[i]
    inc i
  return r

## The scalar shapes std/system declares. aowljs does not replay std modules, so
## their declarations never reach `scanTypeDecls` and a symbol reference to one
## has to be recognised by name. Every entry here is a type whose layout is a
## FIXED runtime shape, not something a user declaration can change.
proc systemDesc(nm: string): TypeDesc =
  if nm == "int" or nm == "int64" or nm == "Natural" or nm == "Positive":
    return scalar(akInt, 64)
  elif nm == "int32": return scalar(akInt, 32)
  elif nm == "int16": return scalar(akInt, 16)
  elif nm == "int8": return scalar(akInt, 8)
  elif nm == "uint" or nm == "uint64": return scalar(akUInt, 64)
  elif nm == "uint32": return scalar(akUInt, 32)
  elif nm == "uint16": return scalar(akUInt, 16)
  elif nm == "uint8" or nm == "byte": return scalar(akUInt, 8)
  elif nm == "float" or nm == "float64": return scalar(akFloat, 64)
  elif nm == "float32": return scalar(akFloat, 32)
  elif nm == "char": return scalar(akChar)
  elif nm == "bool": return scalar(akBool)
  elif nm == "string": return scalar(akString)
  elif nm == "cstring" or nm == "pointer": return scalar(akPtr)
  elif nm == "seq":
    # `seq` is not a NIF tag: nimony instantiates it as an ordinary object type
    # (`seq.0.<hash>`), so a program that declares one reaches the SYMBOL path
    # above with the real fields. This is the fallback for an instance whose
    # declaration aowljs never replayed, and the 2-word header does not depend
    # on the element — `akChar` is a placeholder only the header size may be
    # read from, never the element buffer.
    return seqDesc(scalar(akChar))
  elif nm == "RootObj":
    # The root of every inheritance chain: no fields of its own, but it is what
    # puts the type-header word in front of a derived object. aowlabi spells
    # that `rtti`.
    return objectDesc(@[], rtti = true)
  else:
    return TypeDesc(nil)

# ---------------------------------------------------------------------------
# NIF type node -> TypeDesc
# ---------------------------------------------------------------------------

proc descOf(c: Cursor; depth: int): TypeDesc

proc intLitAt(c: Cursor): int =
  ## the integer a cursor is sitting on, or 0.
  if c.kind == IntLit: return int(pool.integers[c.intId])
  return 0

proc objectDescOf(c: Cursor; depth: int; packed, union, incomplete: bool): TypeDesc =
  ## `(object BASE member*)` where member is `(fld :n EXPORT PRAGMAS TYPE VALUE)`
  ## or `(case DISCFLD (of (ranges …) (stmts member*))* (else (stmts …))?)`.
  var n = c
  inc n                                     # past `object`
  var base = TypeDesc(nil)
  var rtti = false
  if n.kind == Symbol or n.kind == SymbolDef or n.kind == Ident:
    let bnm = pool.syms[n.symId]
    if baseNameOf(bnm) == "RootObj":
      rtti = true
    else:
      base = tdLookup(bnm)
      if base == nil: return TypeDesc(nil)   # an object whose parent we cannot see
    inc n
  elif n.kind == DotToken:
    inc n
  else:
    skip n

  var fields: seq[TypeDesc] = @[]
  var branches: seq[seq[TypeDesc]] = @[]
  var isVariant = false

  while n.kind != ParRi:
    if n.kind == ParLe and n.tagEnum == FldTagId:
      var f = n
      inc f                                  # `fld`
      skip f                                 # name
      skip f                                 # export
      skip f                                 # pragmas
      let d = descOf(f, depth + 1)
      if d == nil: return TypeDesc(nil)
      fields.add d
      skip n
    elif n.kind == ParLe and n.tagEnum == CaseTagId:
      isVariant = true
      var k = n
      inc k                                  # `case`
      # the discriminator is an ordinary field, and aowlabi wants it among the
      # fields BEFORE the case.
      if k.kind == ParLe and k.tagEnum == FldTagId:
        var f = k
        inc f; skip f; skip f; skip f
        let d = descOf(f, depth + 1)
        if d == nil: return TypeDesc(nil)
        fields.add d
      skip k
      while k.kind != ParRi:
        if k.kind == ParLe and (k.tagEnum == OfTagId or k.tagEnum == ElseTagId):
          var b = k
          inc b
          if b.kind == ParLe and b.tagEnum == RangesTagId: skip b
          var bf: seq[TypeDesc] = @[]
          if b.kind == ParLe and b.tagEnum == StmtsTagId:
            inc b
            while b.kind != ParRi:
              if b.kind == ParLe and b.tagEnum == FldTagId:
                var f = b
                inc f; skip f; skip f; skip f
                let d = descOf(f, depth + 1)
                if d == nil: return TypeDesc(nil)
                bf.add d
              skip b
          branches.add bf
        skip k
      skip n
    else:
      skip n

  if isVariant:
    return variantDesc(fields, branches, base, rtti)
  return objectDesc(fields, base, rtti, packed, union, incomplete)

proc descOf(c: Cursor; depth: int): TypeDesc =
  ## The whole mapping. Returns nil for anything not covered — never a guess.
  if depth > 32: return TypeDesc(nil)        # a cycle by value is impossible in
                                             # nimony, but a malformed tree is not
  var n = c
  case n.kind
  of Symbol, SymbolDef, Ident:
    let sym = pool.syms[n.symId]
    let d = tdLookup(sym)
    if d != nil: return d
    return systemDesc(baseNameOf(sym))
  of ParLe:
    let t = n.tagEnum
    if t == ITagId or t == UTagId or t == FTagId:
      var d = n; inc d
      let bits = if d.kind == IntLit: intLitAt(d) else: 64
      if t == ITagId: return scalar(akInt, bits)
      elif t == UTagId: return scalar(akUInt, bits)
      else: return scalar(akFloat, bits)
    elif t == CTagId: return scalar(akChar)
    elif t == BoolTagId: return scalar(akBool)
    elif t == PtrTagId or t == PointerTagId or t == CstringTagId or
         t == ProctypeTagId:
      # nimony's own sizeof.nim puts every routine type on the ptrSize arm; a
      # `{.closure.}` would be two words, but nimony spells that `(proctype …
      # (pragmas (closure)))` and this backend has no corpus for it, so it is
      # left unmapped rather than guessed.
      return scalar(akPtr)
    elif t == RefTagId: return scalar(akRef)
    elif t == StringTagId: return scalar(akString)
    elif t == MutTagId or t == OutTagId or t == SinkTagId or t == LentTagId:
      inc n
      return descOf(n, depth + 1)
    elif t == DistinctTagId:
      inc n
      return descOf(n, depth + 1)            # transparent for layout
    elif t == RangetypeTagId:
      var b = n; inc b
      let bd = descOf(b, depth + 1)
      if bd == nil: return TypeDesc(nil)
      skip b
      let lo = intLitAt(b); skip b
      let hi = intLitAt(b)
      return rangeDesc(bd, lo, hi)
    elif t == SetTagId:
      var b = n; inc b
      let bd = descOf(b, depth + 1)
      if bd == nil: return TypeDesc(nil)
      return setDesc(bd)
    elif t == UarrayTagId or t == FlexarrayTagId:
      var b = n; inc b
      let ed = descOf(b, depth + 1)
      if ed == nil: return TypeDesc(nil)
      return uncheckedDesc(ed)
    elif t == ArrayTagId:
      var b = n; inc b
      let ed = descOf(b, depth + 1)
      if ed == nil: return TypeDesc(nil)
      skip b
      # the length arrives as `(rangetype BASE LO HI)` — the COUNT is hi-lo+1,
      # not hi. Reading it as hi would be right only for a 0-based range, which
      # is every array a corpus happens to contain and none of the point.
      var count = 0
      if b.kind == ParLe and b.tagEnum == RangetypeTagId:
        var r = b; inc r; skip r
        let lo = intLitAt(r); skip r
        let hi = intLitAt(r)
        count = hi - lo + 1
      elif b.kind == IntLit:
        count = intLitAt(b)
      else:
        return TypeDesc(nil)
      return arrayDesc(ed, count)
    elif t == TupleTagId:
      var b = n; inc b
      var fields: seq[TypeDesc] = @[]
      while b.kind != ParRi:
        var ft = b
        if ft.kind == ParLe and ft.tagEnum == KvTagId:
          inc ft                             # `kv`
          skip ft                            # the field name
        let d = descOf(ft, depth + 1)
        if d == nil: return TypeDesc(nil)
        fields.add d
        skip b
      return tupleDesc(fields)
    elif t == EnumTagId or t == OnumTagId:
      var b = n; inc b
      var bits = 0
      let bd = descOf(b, depth + 1)
      if bd != nil: bits = bd.bits
      skip b
      var lo = 0
      var hi = 0
      var first = true
      while b.kind != ParRi:
        if b.kind == ParLe and b.tagEnum == EfldTagId:
          var f = b
          inc f                              # `efld`
          # The ordinal lives in a `(tup ORD "name")`, and the slots before it
          # are not a fixed count — `efld`'s slot 2 carries the export marker OR
          # the compile-time value. Scan FORWARD to the tup rather than counting
          # skips: counting them landed on the type symbol, which is not a tup,
          # so every ordinal silently read as 0. That was invisible only because
          # `enumDesc` prefers the explicit `bits` from the enum's base type
          # whenever there is one — a bug parked behind another field's answer.
          while f.kind != ParRi and not (f.kind == ParLe and f.tagEnum == TupTagId):
            skip f
          if f.kind == ParLe and f.tagEnum == TupTagId:
            inc f
            let ord = intLitAt(f)
            if first: (lo = ord; hi = ord; first = false)
            elif ord < lo: lo = ord
            elif ord > hi: hi = ord
        skip b
      return enumDesc(lo, hi, bits)
    elif t == ObjectTagId:
      return objectDescOf(n, depth, false, false, false)
    else:
      return TypeDesc(nil)
  else:
    return TypeDesc(nil)

# ---------------------------------------------------------------------------
# the scan pass
# ---------------------------------------------------------------------------

proc registerTypeDecl(c: Cursor) =
  ## `(type :NAME EXPORT TYPEVARS PRAGMAS BODY)`. The pragmas that change LAYOUT
  ## — `packed`, `union`, `incompleteStruct` — sit on the decl, not on the
  ## `(object …)`, so they are read here and handed down.
  var n = c
  inc n                                      # `type`
  if not (n.kind == Symbol or n.kind == SymbolDef or n.kind == Ident): return
  let sym = pool.syms[n.symId]
  inc n                                      # name
  skip n                                     # export
  skip n                                     # typevars
  var packed = false
  var union = false
  var incomplete = false
  if n.kind == ParLe and n.tagEnum == PragmasTagId:
    var p = n
    inc p
    while p.kind != ParRi:
      if p.kind == ParLe:
        let pt = p.tagEnum
        if pt == PackedTagId: packed = true
        elif pt == UnionTagId: union = true
        elif pt == IncompleteStructTagId: incomplete = true
      skip p
  skip n                                     # pragmas

  var d = TypeDesc(nil)
  if n.kind == ParLe and n.tagEnum == ObjectTagId:
    d = objectDescOf(n, 0, packed, union, incomplete)
  else:
    d = descOf(n, 0)
  if d == nil: return
  # A generic type is emitted once per instantiation under the SAME base name
  # but a different symbol, so key on the full symbol and let the last write for
  # a given symbol win (re-scanning a module is otherwise harmless).
  for i in 0 ..< tdKeys.len:
    if tdKeys[i] == sym:
      tdVals[i] = d
      return
  tdKeys.add sym
  tdVals.add d

proc scanTypeDecls*(n: var Cursor) =
  ## walk the tree, registering every `(type …)`. Accumulates across modules, so
  ## a type declared in an imported module is visible to a `sizeof` in the main
  ## one — which is the order aowljs already emits in.
  if n.kind != ParLe:
    inc n
    return
  if n.tagEnum == TypeTagId:
    registerTypeDecl(n)
    skip n
  else:
    inc n
    while n.kind != ParRi: scanTypeDecls(n)
    consumeParRi n

# ---------------------------------------------------------------------------
# the answer
# ---------------------------------------------------------------------------

proc abiSizeOf*(c: Cursor): int =
  ## The size in bytes of the type this cursor names, or **-1** when the mapping
  ## does not cover it. -1 is not a size and must never be printed as one.
  let d = descOf(c, 0)
  if d == nil: return -1
  # `validate` is aowlabi's own "this descriptor is under-specified" check — a
  # seq with no element type, an incompleteStruct whose real size is the C
  # compiler's. Answering anyway would be a number nobody can stand behind.
  if validate(d).len > 0: return -1
  return sizeAlign(d, 8).size
