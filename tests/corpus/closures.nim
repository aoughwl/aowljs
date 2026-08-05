## BLOCKED, on purpose. aowljs transpiles this correctly (11|12|101|13|15|20),
## but nimony's own hexer cannot build it — lambdalifting asserts
## `env.s != SymId(0)` on a closure that captures a local and is RETURNED from
## the proc owning it — so there is no reference output to compare against. It
## stays in the corpus so the gate reports the gap every run, and starts
## comparing by itself the day the toolchain can run it.
import std/syncio
proc counter(start: int): proc (): int {.closure.} =
  var n = start
  result = proc (): int {.closure.} =
    n = n + 1
    result = n
var c = counter(10)
echo c()
echo c()
var d = counter(100)
echo d()
echo c()
proc apply(f: proc (x: int): int {.closure.}; v: int): int = f(v)
echo apply(proc (x: int): int {.closure.} = x * 3, 5)
var mul = 4
echo apply(proc (x: int): int {.closure.} = x * mul, 5)
