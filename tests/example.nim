import nimscripter
import nimscripter/expose
import example/objects
import compiler/nimeval
import json
proc doStuff(a: ComplexObject) {.exportToScript: test.} = echo a
proc doStuffA(a: SomeRef) {.exportToScript: test.} = echo a.a
proc doStuffB(a: seq[int]) {.exportToScript: test.} = echo a
const
  testProc = implNimscriptModule(test)
  stdlib = findNimStdlibCompileTime()
let
  intr = loadScript("tests/example/first.nims", testProc, modules = ["objects"], stdpath = stdlib)
  res = intr.get.invoke(fromJson, returnType = JsonNode)
echo res.pretty
intr.get.invoke(echoObj, ComplexObject(someBool: false, someInt: 320, someintTwo: 42))
intr.get.invoke(echoObj, %*(ComplexObject(someBool: false, someInt: 320, someintTwo: 42)))
