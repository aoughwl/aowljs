## Seq allocation and indexed access.
import std/syncio
proc build(n: int): seq[int] =
  result = @[]
  for i in 0 ..< n: result.add i * 2
proc total(xs: seq[int]): int =
  result = 0
  for i in 0 ..< xs.len: result = result + xs[i]
var xs = build(2000000)
echo total(xs)
