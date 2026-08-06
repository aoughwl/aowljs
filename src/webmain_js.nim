## webmain_js.nim — the browser entry for aifjs, mirroring aifi/src/nifi/webmain.nim.
## The JS glue parks a `.s.nif` string on `globalThis.__nifi_src`; we parse it in
## memory, walk it with the emitter, and hand the produced JavaScript back on
## `globalThis.__njs_out`. No file I/O — the same shape as aifi's web entry.
##
## ⚠️ STATUS: THIS FILE DOES NOT BUILD, and nothing builds it. `build.sh` and the
## gates only ever touch `aifjs_cli.nim`. Two of its imports no longer resolve:
##
##   * `".." / ".." / "aifi" / src / aifi / programs` — a hardcoded relative path
##     to a sibling checkout that was renamed `aifi` -> `aowli`. The CLI just
##     says `import programs` and lets the search path find it, which works.
##   * `jsffi` — there is no jsffi module anywhere in the nimony tree, so
##     `global`/`toJs`/`.set` have no definitions and this cannot compile as
##     written.
##
## Kept because the SHAPE is right — parse from memory, emit, hand the string
## back on a global, no file I/O — and because the browser path is wanted. But it
## is a design sketch, not working code, and the playground's *Native JS* engine
## is served by `aoughwl/aifjs-js` today, not by this.

when defined(nimony):
  {.feature: "lenientnils".}

import nifcursors
import ".." / ".." / "aifi" / src / aifi / programs
import emitjs
import jsffi

proc compileToJs(src: string): string =
  ## Parse `.s.nif` bytes from memory and emit native JavaScript for them.
  setupProgramForTesting("", "webmod", ".s.nif")
  var buf = parseFromBuffer(src, "webmod")
  var root = beginRead(buf)
  result = emitModule(root)

proc njsRun() =
  ## Module-init entry (NOT `{.exportc:"main".}` — see aifi's webmain note).
  let src = global("__nifi_src").toStr
  let js = compileToJs(src)
  let g = global("globalThis")
  g.set("__njs_out", toJs(js))

njsRun()
