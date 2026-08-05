## BLOCKED, on purpose. Two `defer`s in one proc: each one's lowering introduces
## a temporary, both get the SAME name in the same C scope, and nimony's own C
## output fails to compile with "redefinition of 'X60Qffv_0'". sem succeeds, so
## aowljs transpiles it and answers "ab21" — defers run in REVERSE declaration
## order, which is the right answer — but there is no reference output to compare
## against. Filed to aowlsem. It starts comparing by itself once nimony can build
## it.
import std/syncio
proc twoDefers(): string =
  result = "a"
  defer: result = result & "1"
  defer: result = result & "2"
  result = result & "b"
echo twoDefers()
