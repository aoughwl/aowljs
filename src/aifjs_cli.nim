## nifjs_cli — transpile a sem'd `.s.nif` module (and its imported USER modules,
## in dependency-first order) to JavaScript on stdout.
##
##   aifjs [--faithful] <path-to-main-module.s.nif>
##
## Imported user modules are pulled in via the shared HL-IR loader
## (`aowlhl/hlload`) so their top-level declarations/procs are emitted before the
## main module — matching native module-initialization order. Std/system modules
## are handled by the runtime shim, not replayed.
when defined(nimony):
  {.feature: "lenientnils".}
import std/[syncio, os]
import nifcursors, nifstreams, programs
import aowlhl/hlload
import emitjs

proc stripSNif(fname: string): string =
  result = fname
  let n = result.len
  if n > 6 and result[n-6 .. n-1] == ".s.nif":
    result = result[0 .. n-7]

proc emitFile(path: string): string =
  var buf = parseFromFile(path)
  var root = beginRead(buf)
  result = emitModuleBody(root)
  endRead buf

proc main =
  var path = ""
  var faithful = false
  let params = commandLineParams()
  for p in params:
    if p == "--faithful":
      faithful = true
    elif p.len > 0 and p[0] != '-' and path.len == 0:
      path = p
  if path.len == 0:
    write stderr, "aifjs: usage: aifjs [--faithful] <module.s.nif>\n"
    quit 2
  if not fileExists(path):
    write stderr, "aifjs: cannot read file\n"
    quit 1
  setFaithful(faithful)
  let dir = parentDir(path)
  let mainKey = stripSNif(extractFilename(path))
  setupProgramForTesting(dir, mainKey, ".s.nif")

  var outp = jsPrelude()
  # imported USER modules first (dependency-first), then the main module.
  for key in moduleInitOrder(dir, path):
    if key == mainKey: continue
    let p = dir / (key & ".s.nif")
    if fileExists(p):
      outp.add "\n// --- module " & key & " ---\n"
      outp.add emitFile(p)
  outp.add "\n// --- main module ---\n"
  outp.add emitFile(path)
  outp.add jsFlush()

  write stdout, outp

main()
