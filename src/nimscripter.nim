import compiler / [nimeval, renderer, ast, types, llstream, vmdef, vm]
import os, osproc, strutils, algorithm
import nimscripterhelper
import awbject
import json
# This uses your Nim install to find the standard library instead of hard-coding it
var
  nimdump = execProcess("nim dump")
  nimlibs = nimdump[nimdump.find("-- end of list --")+18..^2].split
nimlibs.sort


proc fire(damage: int, x, y: float32){.scripted.}=
  echo damage, " ", x, " ", y

proc cry(doCry: bool, message: string){.scripted.}=
  if doCry: echo message
  else: echo "You are not sad"

proc kill(a: Awbject){.scripted.}=
  echo a.a 

proc hmm(a: Awbject): Awbject {.scripted.}= Awbject(a: a.a - 10)

const scriptAdditions = static:
  #Due to our reliance on json for object transfer need json
  var scriptAddition = """
import json
import src/awbject
import macros, sets
const 
  intNames = ["int", "int8", "int16", "int32", "int64", "uint", "uint8", "byte", "uint16", "uint32", "uint64"].toHashSet
  floatNames = ["float32", "float", "float64"].toHashSet

proc isPrimitive(str: string): bool = str in intNames + floatNames + ["bool", "string"].toHashSet

macro interoped(procDef: untyped): untyped =
  var 
    newProcArgs: seq[NimNode]
    oldProcTypes: seq[NimNode]
  if not ($procDef[3][0]).isPrimitive:
    newProcArgs.add ident("string")


  for param in procDef[3]:
    if param.kind == nnkIdentDefs:
      #For each declared variable here
      for declared in 0..<(param.len-2):
        #If it's not a primitive convert to json, else just send it
        newProcArgs.add(param)
        oldProcTypes.add(param[^2])
        if not ($param[^2]).isPrimitive:
          newProcArgs[^1][^2] = ident("string")
  
  var 
    newBody = newStmtList()
    args: seq[NimNode]
  args.add(procDef[0])
  for i, arg in newProcArgs:
      for declared in 0..<(arg.len-2):
        args.add(arg[declared])
        newBody.add newLetStmt(arg[declared], newCall(newNimNode(nnkBracketExpr).add(ident("fromString"),oldProcTypes[declared]), arg[declared]))
  newBody.add newDotExpr(newNimNode(nnkCall).add(args), ident("toString"))
  let exposedProc = newProc(postfix(procDef[0], "*"), newProcArgs, newBody)
  result = newStmtList(procDef, exposedProc)

proc fromString[T: object](a: string): T = parseJson(a).to(T)
proc toString(a: object): string = $(% a)
"""
  for scriptProc in scriptTable:
    scriptAddition &= scriptProc.vmCompDefine
    scriptAddition &= scriptProc.vmRunDefine
  scriptAddition

proc toPNode*[T: object](a: T): PNode = newStrNode(nkStrLit, $ (%a))

proc loadScript(path: string, modules: varargs[string]): Interpreter=
  var additions = scriptAdditions
  
  for `mod` in modules:
    additions.insert("import " & `mod` & "\n", 0)

  let
    scriptName = path.splitFile.name
    intr = createInterpreter(path, nimlibs)
    script = readFile(path)

  for scriptProc in scriptTable:
    intr.implementRoutine("*", scriptname, scriptProc.name & "Comp", scriptProc.vmProc)
  intr.evalScript(llStreamOpen(additions & script))
  writeFile("scripts2.nims", additions & script)
  intr

proc invoke(intr: Interpreter, procName: string, args: openArray[PNode] = [], T: typeDesc): T=
  let 
    foreignProc = intr.selectRoutine(procName)
    ret = intr.callRoutine(foreignProc, args)
  when T is SomeOrdinal:
    ret.intVal.T
  elif T is SomeFloat:
    ret.floatVal.T
  elif T is string:
    ret.strVal
  else:
    to((ret.strVal).parseJson, T)
  
let intrptr = loadScript("script.nims", "src/awbject")
var a: Awbject = intrptr.invoke("update", [Awbject(a: 1000).toPNode], Awbject)
echo a
intrptr.destroyInterpreter()
