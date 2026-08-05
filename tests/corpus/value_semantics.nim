## VALUE semantics. A nimony object/tuple/array/seq is a value: assigning one
## copies it. The JS objects and arrays they map onto are references, so every
## one of these was silently aliasing — 6 of the 12 answers below were wrong, with
## no crash and no warning. `ref object` must still SHARE, which is what the
## `__ref` marker on `newobj` is for; the methods/ tests cover that side.
import std/syncio
type P = object
  x: int
  y: int

# object assignment is a COPY in nimony, a reference share in JS
var a = P(x: 1, y: 2)
var b = a
b.x = 99
echo a.x        # 1 if copied, 99 if shared
echo b.x

# passing an object by value must not let the callee mutate the caller's
proc mutate(p: P): int =
  var q = p
  q.x = 77
  result = q.x
echo mutate(a)
echo a.x

# seq assignment is also a copy
var s1 = @[1, 2, 3]
var s2 = s1
s2[0] = 50
echo s1[0]
echo s2[0]

# an object inside a seq: reading one out gives a copy
var ps = @[P(x: 5, y: 6)]
var taken = ps[0]
taken.x = 42
echo ps[0].x
echo taken.x

# ...but writing through the index must hit the seq
ps[0].x = 11
echo ps[0].x

# an array of objects
var arr = [P(x: 1, y: 1), P(x: 2, y: 2)]
var first = arr[0]
first.y = 9
echo arr[0].y

# nested object copy
type Outer = object
  inner: P
  tag: int
var o1 = Outer(inner: P(x: 3, y: 4), tag: 1)
var o2 = o1
o2.inner.x = 88
echo o1.inner.x
echo o2.inner.x
