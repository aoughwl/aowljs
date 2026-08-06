## A tight integer loop: the shape the speed claim is about.
import std/syncio
proc run(n: int): int =
  result = 0
  var i = 0
  while i < n:
    result = result + i * 3 - (i div 2)
    i = i + 1
echo run(20000000)
