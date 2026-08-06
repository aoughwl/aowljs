## A case-EXPRESSION in a hot loop: the other IIFE site.
import std/syncio
proc classify(n: int): int =
  result = case n mod 5
           of 0: 1
           of 1, 2: 2
           of 3: 3
           else: 4
proc run(n: int): int =
  result = 0
  var i = 0
  while i < n:
    result = result + classify(i)
    i = i + 1
echo run(10000000)
