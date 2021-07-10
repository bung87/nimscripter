import compiler / [nimeval, renderer, ast, llstream, vmdef, vm, lineinfos]
import std/[os, json, options,]
export destroyInterpreter, options, Interpreter

import nimscripter/[marshalns, procsignature]
export marshalns

const scriptAdditions = """

proc saveInt(a: BiggestInt): string = discard

proc saveString(a: string): string = discard

proc saveBool(a: bool): string = discard

proc saveFloat(a: BiggestFloat): string = discard

proc getString(a: string, len: int, buf: string, pos: int): string = discard

proc getFloat(buf: string, pos: BiggestInt): BiggestFloat = discard

proc getInt(buf: string, pos: BiggestInt): BiggestInt = discard

import strutils

proc addToBuffer*[T](a: T, buf: var string) =
  when T is object or T is tuple or T is ref object:
    when T is ref object:
      addToBuffer(a.isNil, buf)
      if a.isNil: return
      for field in a[].fields:
        addToBuffer(field, buf)
    else:
      for field in a.fields:
        addToBuffer(field, buf)
  elif T is seq:
    addToBuffer(a.len, buf)
    for x in a:
      addToBuffer(x, buf)
  elif T is array:
    for x in a:
      addToBuffer(x, buf)
  elif T is SomeFloat:
    buf &= saveFloat(a.BiggestFloat)
  elif T is SomeOrdinal:
    buf &= saveInt(a.BiggestInt)
  elif T is string:
    buf &= saveString(a)


proc getFromBuffer*[T](buff: string, pos: var BiggestInt): T =
  if(pos > buff.len): echo "Buffer smaller than datatype requested"
  when T is object or T is tuple or T is ref object:
    when T is ref object:
      let isNil = getFromBuffer[bool](buff, pos)
      if isNil:
        return nil
      else: result = T()
      for field in result[].fields:
        field = getFromBuffer[field.typeof](buff, pos)
    else:
      for field in result.fields:
        field = getFromBuffer[field.typeof](buff, pos)
  elif T is seq:
    result.setLen(getFromBuffer[int](buff, pos))
    for x in result.mitems:
      x = getFromBuffer[typeof(x)](buff, pos)
  elif T is array:
    for x in result.mitems:
      x = getFromBuffer[typeof(x)](buff, pos)
  elif T is SomeFloat:
    result = getFloat(buff, pos).T
    pos += sizeof(BiggestInt)
  elif T is SomeOrdinal:
    result = getInt(buff, pos).T
    pos += sizeof(BiggestInt)
  elif T is string:
    let len = getFromBuffer[BiggestInt](buff, pos)
    result = buff[pos..<(pos + len)]
    pos += len

import macros
macro exportToNim(input: untyped): untyped=
  let 
    exposed = copy(input)
    hasRetVal = input[3][0].kind != nnkEmpty
  if exposed[0].kind == nnkPostfix:
    exposed[0][0] = ident($exposed[0][0] & "Exported")
  else:
    exposed[0] = postfix(ident($exposed[0] & "Exported"), "*")
  if hasRetVal:
    exposed[3][0] = ident("string")

  if exposed[3].len > 2:
    exposed[3].del(2, exposed[3].len - 2)
  if exposed[3].len > 1:
    exposed[3][1] = newIdentDefs(ident("parameters"), ident("string"))
  
  let
    buffIdent = ident("parameters")
    posIdent = ident("pos")
  var
    params: seq[NimNode]
    expBody = newStmtList().add quote do:
      var `posIdent`: BiggestInt = 0
  for identDefs in input[3][1..^1]:
    let idType = identDefs[^2]
    for param in identDefs[0..^3]:
      params.add param
      expBody.add quote do:
        let `param` = getFromBuffer[`idType`](`buffIdent`, `posIdent`)
  let procName = if input[0].kind == nnkPostfix: input[0][0] else: input[0]
  if hasRetVal:
    expBody.add quote do:
      `procName`().addToBuffer(result)
    if params.len > 0: expBody[^1][0][0].add params
  else:
    expBody.add quote do:
      `procName`()
    if params.len > 0: expBody[^1].add params
  exposed[^1] = expBody
  result = newStmtList(input, exposed)
"""

type
  VMQuit* = object of CatchableError
    info*: TLineInfo

proc implementInteropRoutines(i: Interpreter, scriptName: string) =
  i.implementRoutine("*", scriptname, "saveInt", proc(vm: VmArgs) =
    let a = vm.getInt(0)
    vm.setResult(saveInt(a))
  )
  i.implementRoutine("*", scriptname, "saveFloat", proc(vm: VmArgs) =
    let a = vm.getFloat(0)
    vm.setResult(saveFloat(a))
  )
  i.implementRoutine("*", scriptname, "saveString", proc(vm: VmArgs) =
    let a = vm.getstring(0)
    vm.setResult(saveString(a))
  )
  i.implementRoutine("*", scriptname, "getInt", proc(vm: VmArgs) =
    let
      buf = vm.getString(0)
      pos = vm.getInt(1)
    vm.setResult(getInt(buf, pos))
  )
  i.implementRoutine("*", scriptname, "getFloat", proc(vm: VmArgs) =
    let
      buf = vm.getString(0)
      pos = vm.getInt(1)
    vm.setResult(getFloat(buf, pos))
  )

proc getSearchPath(path: string): seq[string] =
  result.add path
  for dir in walkDirRec(path, {pcDir}):
    result.add dir

proc loadScript*(
  script: string,
  userProcs: openArray[VmProcSignature],
  isFile = true,
  modules: varargs[string],
  stdPath = "./stdlib"): Option[Interpreter] =

  if not isFile or fileExists(script):
    var additions = scriptAdditions
    when defined(jsoninterop):
      additions.add "import std/json \n"
    for `mod` in modules: # Add modules
      additions.insert("import " & `mod` & "\n", 0)

    for uProc in userProcs:
      additions.add uProc.vmStringImpl
      additions.add uProc.vmRunImpl

    var searchPaths = getSearchPath(stdPath)
    let scriptName = if isFile: script.splitFile.name else: "script"

    if isFile: # If is file we want to enable relative imports
      searchPaths.add script.parentDir

    let
      intr = createInterpreter(scriptName, searchPaths)
      script = if isFile: readFile(script) else: script

    intr.implementInteropRoutines(scriptName)

    for uProc in userProcs:
      intr.implementRoutine("*", scriptName, uProc.vmStringName, uProc.vmProc)

    when defined(debugScript): writeFile("debugScript.nims", additions & script)

    #Throws Error so we can catch it
    intr.registerErrorHook proc(config, info, msg, severity: auto) {.gcsafe.} =
      if severity == Error and config.error_counter >= config.error_max:
        echo "Script Error: ", info, " ", msg
        raise (ref VMQuit)(info: info, msg: msg)
    try:
      intr.evalScript(llStreamOpen(additions & script))
      result = option(intr)
    except:
      discard
  else:
    when defined(debugScript):
      echo "File not found"

proc loadScript*(
  script: string,
  isFile = true,
  modules: varargs[string],
  stdPath = "./stdlib"): Option[Interpreter] {.inline.} =
  loadScript(script, [], isFile, modules, stdPath)


proc invoke*(intr: Interpreter, procName: string, argBuffer: string = "", T: typeDesc = void): T =
  let
    foreignProc = intr.selectRoutine(procName & "Exported")
  var ret: PNode
  if argBuffer.len > 0:
    ret = intr.callRoutine(foreignProc, [newStrNode(nkStrLit, argBuffer)])
  else:
    ret = intr.callRoutine(foreignProc, [])
  when T isnot void:
    var pos: BiggestInt
    getFromBuffer[T](ret.strVal, pos)
