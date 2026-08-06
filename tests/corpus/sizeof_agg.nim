## `sizeof` of an AGGREGATE — the one FEATURE gap aowljs reported across the
## whole corpus, and the only one with a real oracle: nimony folds `sizeof` in
## its own backend, so this program's stdout under nimony IS the right answer.
##
## Every row is a shape whose size cannot be guessed from a scalar table:
## padding between differently-aligned fields, an inherited base, a variant's
## largest branch, an array of a padded element, a nested aggregate.

import std/syncio

type
  Mixed = object       ## char, pointer-sized, narrow — padding on both sides
    a: char
    b: int
    c: int32
  Narrow = object
    a: char
    b: int32
    c: int16
  Base = object of RootObj
    a: char
  Derived = object of Base
    b: int32
  Nested = object
    m: Mixed
    n: Narrow
  Packed {.packed.} = object
    a: char
    b: int
    c: char
  Kind = enum
    kA, kB
  Var = object
    case k: Kind
    of kA: p: pointer
    of kB: c: char
  Pair = tuple[a: char, b: int]
  ## A `set` is the one shape whose size comes from the base type's ORDINAL
  ## RANGE rather than its width, so it is the row that can tell a correctly
  ## read enum ordinal from a zero. With 21 values `set[Wide]` is 4 bytes; if
  ## every ordinal read as 0 it would be 1.
  Wide = enum
    w00, w01, w02, w03, w04, w05, w06, w07, w08, w09,
    w10, w11, w12, w13, w14, w15, w16, w17, w18, w19, w20

proc main =
  echo sizeof(Mixed)
  echo sizeof(Narrow)
  echo sizeof(Base)
  echo sizeof(Derived)
  echo sizeof(Nested)
  echo sizeof(Packed)
  echo sizeof(Var)
  echo sizeof(Pair)
  echo sizeof(array[3, Mixed])
  echo sizeof(array[2, char])
  echo sizeof(seq[int32])
  echo sizeof(string)
  # The scalars are here too, because they used to be answered by a SECOND
  # table inside the emitter, and that table put `cstring` on the two-word arm
  # with `string`: 16, where nimony says 8. A scalar row is not redundant with
  # the aggregate ones — it is the row that caught the duplicate.
  echo sizeof(cstring)
  echo sizeof(pointer)
  echo sizeof(int)
  echo sizeof(int32)
  echo sizeof(int16)
  echo sizeof(int8)
  echo sizeof(float32)
  echo sizeof(char)
  echo sizeof(bool)
  echo sizeof(Kind)
  echo sizeof(Wide)
  echo sizeof(set[Wide])
  echo sizeof(set[char])
  echo sizeof(range[0 .. 40])

main()
