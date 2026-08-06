## BLOCKED, on purpose. A `method` carrying a `{.raises.}` pragma SEGFAULTS the
## binary nimony produces — sem and the C emission both succeed, and the program
## dies at run time. gcc warns on that same C with "'return' with no value, in
## function returning non-void", a bare `return;` out of a struct-returning
## function, which is undefined behaviour and the likely cause. (The same defect
## was fixed in aowlc this session; here it is fatal rather than survivable.)
##
## Narrowed: the same shape WITHOUT methods — plain procs, try/finally, an
## iterator, an exception crossing a for loop — runs correctly and only warns.
## It is methods + raises.
##
## aowljs transpiles this correctly (base1 / err:neg / impl3 / err:empty), so
## there is simply no reference output to compare against. Filed to aowlsem; it
## starts comparing by itself once nimony can run it.
import std/syncio
type
  E = ref object of Exception
    code: int
  Base = ref object of RootObj
    id: int
  Impl = ref object of Base
    extra: seq[string]
method describe(b: Base): string {.base, raises: E.} =
  if b.id < 0: raise E(msg: "neg", code: b.id)
  result = "base" & $b.id
method describe(i: Impl): string {.raises: E.} =
  if i.extra.len == 0: raise E(msg: "empty", code: 0)
  result = "impl" & $i.id
proc safe(b: Base): string =
  result = "?"
  try:
    result = describe(b)
  except E as e:
    result = "err:" & e.msg
echo safe(Base(id: 1))
echo safe(Base(id: -2))
echo safe(Impl(id: 3, extra: @["x"]))
echo safe(Impl(id: 4, extra: @[]))
