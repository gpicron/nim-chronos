#
#
#            Nim's Runtime Library
#        (c) Copyright 2015 Dominik Picheta
#
#    See the file "copying.txt", included in this
#    distribution, for details about the copyright.
#

import std/[macros]

proc skipUntilStmtList(node: NimNode): NimNode {.compileTime.} =
  # Skips a nest of StmtList's.
  result = node
  if node[0].kind == nnkStmtList:
    result = skipUntilStmtList(node[0])

proc processBody(node, retFutureSym: NimNode,
                 subTypeIsVoid: bool): NimNode {.compileTime.} =
  #echo(node.treeRepr)
  result = node
  case node.kind
  of nnkReturnStmt:
    result = newNimNode(nnkStmtList, node)

    # As I've painfully found out, the order here really DOES matter.
    if node[0].kind == nnkEmpty:
      if not subTypeIsVoid:
        result.add newCall(newIdentNode("complete"), retFutureSym,
            newIdentNode("result"))
      else:
        result.add newCall(newIdentNode("complete"), retFutureSym)
    else:
      let x = node[0].processBody(retFutureSym, subTypeIsVoid)
      if x.kind == nnkYieldStmt: result.add x
      else:
        result.add newCall(newIdentNode("complete"), retFutureSym, x)

    result.add newNimNode(nnkReturnStmt, node).add(newNilLit())
    return # Don't process the children of this return stmt
  of RoutineNodes-{nnkTemplateDef}:
    # skip all the nested procedure definitions
    return node
  else: discard

  for i in 0 ..< result.len:
    # We must not transform nested procedures of any form, otherwise
    # `retFutureSym` will be used for all nested procedures as their own
    # `retFuture`.
    result[i] = processBody(result[i], retFutureSym, subTypeIsVoid)

proc getName(node: NimNode): string {.compileTime.} =
  case node.kind
  of nnkSym:
    return node.strVal
  of nnkPostfix:
    return node[1].strVal
  of nnkIdent:
    return node.strVal
  of nnkEmpty:
    return "anonymous"
  else:
    error("Unknown name.")

proc isInvalidReturnType(typeName: string): bool =
  return typeName notin ["Future"] #, "FutureStream"]

proc verifyReturnType(typeName: string) {.compileTime.} =
  if typeName.isInvalidReturnType:
    error("Expected return type of 'Future' got '" & typeName & "'")

macro unsupported(s: static[string]): untyped =
  error s

proc params2*(someProc: NimNode): NimNode =
  if someProc.kind == nnkProcTy:
    someProc[0]
  else:
    params(someProc)


proc asyncSingleProc(prc, raises: NimNode, trackExceptions: bool): NimNode {.compileTime.} =
  ## This macro transforms a single procedure into a closure iterator.
  ## The ``async`` macro supports a stmtList holding multiple async procedures.
  if prc.kind notin {nnkProcDef, nnkLambda, nnkMethodDef, nnkDo, nnkProcTy}:
      error("Cannot transform this node kind into an async proc." &
            " proc/method definition or lambda node expected.")

  var
    raisesTuple =
      if raises.len > 0:
        nnkTupleConstr.newTree()
      else:
        ident("void")
    foundRaises = -1

  for index, pragma in pragma(prc):
    if pragma.kind == nnkExprColonExpr and pragma[0] == ident "raises":
      warning("The raises pragma doesn't work on async procedure. " &
        "Use asyncraises instead")
      foundRaises = index
  if foundRaises >= 0: pragma(prc).del(foundRaises)

  for possibleRaise in raises:
    raisesTuple.add(possibleRaise)

  let returnType = prc.params2[0]
  var baseType: NimNode
  # Verify that the return type is a Future[T]
  if returnType.kind == nnkBracketExpr:
    let fut = repr(returnType[0])
    verifyReturnType(fut)
    baseType = returnType[1]
  elif returnType.kind in nnkCallKinds and returnType[0].eqIdent("[]"):
    let fut = repr(returnType[1])
    verifyReturnType(fut)
    baseType = returnType[2]
  elif returnType.kind == nnkEmpty:
    baseType = returnType
  else:
    verifyReturnType(repr(returnType))

  let subtypeIsVoid = returnType.kind == nnkEmpty or
    (baseType.kind == nnkIdent and returnType[1].eqIdent("void"))

  var outerProcBody = newNimNode(nnkStmtList, prc)

  let
    internalFutureType =
      if subtypeIsVoid:
        newNimNode(nnkBracketExpr, prc).add(newIdentNode("Future")).add(newIdentNode("void"))
      elif returnType.kind in nnkCallKinds and returnType[0].eqIdent("[]"):
        newNimNode(nnkBracketExpr, prc).add(newIdentNode("Future")).add(returnType[2])
      else: returnType
    returnTypeWithException =
      newNimNode(nnkBracketExpr).
      add(newIdentNode("RaiseTrackingFuture")).
      add(internalFutureType[1]).
      add(raisesTuple)

  #Rewrite return type
  if trackExceptions:
    prc.params2[0] = nnkBracketExpr.newTree(
      newIdentNode("RaiseTrackingFuture"),
      internalFutureType[1],
      raisesTuple
    )
  elif subtypeIsVoid:
    prc.params2[0] = internalFutureType

  # -> iterator nameIter(chronosInternalRetFuture: Future[T]): FutureBase {.closure.} =
  # ->   {.push warning[resultshadowed]: off.}
  # ->   var result: T
  # ->   {.pop.}
  # ->   <proc_body>
  # ->   complete(chronosInternalRetFuture, result)
  let internalFutureSym = ident "chronosInternalRetFuture"
  var procBody =
    if prc.kind == nnkProcTy: newNimNode(nnkEmpty)
    else: prc.body.processBody(internalFutureSym, subtypeIsVoid)
  # don't do anything with forward bodies (empty)
  if procBody.kind != nnkEmpty:
    let prcName = prc.name.getName
    var iteratorNameSym = genSym(nskIterator, $prcName)
    if subtypeIsVoid:
      let resultTemplate = quote do:
        template result: auto {.used.} =
          {.fatal: "You should not reference the `result` variable inside" &
                   " a void async proc".}
      procBody = newStmtList(resultTemplate, procBody)

    # fix #13899, `defer` should not escape its original scope
    procBody = newStmtList(newTree(nnkBlockStmt, newEmptyNode(), procBody))

    if not subtypeIsVoid:
      procBody.insert(0, newNimNode(nnkPragma).add(newIdentNode("push"),
        newNimNode(nnkExprColonExpr).add(newNimNode(nnkBracketExpr).add(
          newIdentNode("warning"), newIdentNode("resultshadowed")),
        newIdentNode("off")))) # -> {.push warning[resultshadowed]: off.}

      procBody.insert(1, newNimNode(nnkVarSection, prc.body).add(
        newIdentDefs(newIdentNode("result"), baseType))) # -> var result: T

      procBody.insert(2, newNimNode(nnkPragma).add(
        newIdentNode("pop"))) # -> {.pop.})

      procBody.add(
        newCall(newIdentNode("complete"),
          internalFutureSym, newIdentNode("result"))) # -> complete(chronosInternalRetFuture, result)
    else:
      # -> complete(chronosInternalRetFuture)
      procBody.add(newCall(newIdentNode("complete"), internalFutureSym))

    let internalFutureParameter = nnkIdentDefs.newTree(internalFutureSym, internalFutureType, newEmptyNode())
    var closureIterator = newProc(iteratorNameSym, [newIdentNode("FutureBase"), internalFutureParameter],
                                  procBody, nnkIteratorDef)
    closureIterator.pragma = newNimNode(nnkPragma, lineInfoFrom=prc.body)
    closureIterator.addPragma(newIdentNode("closure"))
    # **Remark 435**: We generate a proc with an inner iterator which call each other
    # recursively. The current Nim compiler is not smart enough to infer
    # the `gcsafe`-ty aspect of this setup, so we always annotate it explicitly
    # with `gcsafe`. This means that the client code is always enforced to be
    # `gcsafe`. This is still **safe**, the compiler still checks for `gcsafe`-ty
    # regardless, it is only helping the compiler's inference algorithm. See
    # https://github.com/nim-lang/RFCs/issues/435
    # for more details.
    closureIterator.addPragma(newIdentNode("gcsafe"))

    let closureRaises = raises.copy()
    closureRaises.add(ident("CancelledError"))
    when (NimMajor, NimMinor) < (1, 4):
      closureRaises.add(ident("Defect"))

    closureIterator.addPragma(nnkExprColonExpr.newTree(
      newIdentNode("raises"),
      closureRaises
    ))

    # If proc has an explicit gcsafe pragma, we add it to iterator as well.
    if prc.pragma.findChild(it.kind in {nnkSym, nnkIdent} and
                            it.strVal == "gcsafe") != nil:
      closureIterator.addPragma(newIdentNode("gcsafe"))
    outerProcBody.add(closureIterator)

    # -> var resultFuture = newRaiseTrackingFuture[T ,E]()
    # declared at the end to be sure that the closure
    # doesn't reference it, avoid cyclic ref (#203)
    var retFutureSym = ident "resultFuture"
    var subRetType =
      if returnType.kind == nnkEmpty:
        newIdentNode("void")
      else:
        baseType
    # Do not change this code to `quote do` version because `instantiationInfo`
    # will be broken for `newFuture()` call.
    outerProcBody.add(
      newVarStmt(
        retFutureSym,
        newCall(newTree(nnkBracketExpr, ident "newRaiseTrackingFuture", subRetType, raisesTuple),
                newLit(prcName))
      )
    )
 
    # -> resultFuture.closure = iterator
    outerProcBody.add(
       newAssignment(
        newDotExpr(retFutureSym, newIdentNode("closure")),
        iteratorNameSym)
    )

    # -> futureContinue(resultFuture))
    outerProcBody.add(
        newCall(newIdentNode("futureContinue"), retFutureSym)
    )

    # -> return resultFuture
    outerProcBody.add newNimNode(nnkReturnStmt, prc.body[^1]).add(retFutureSym)

  if prc.kind != nnkLambda and prc.kind != nnkProcTy: # TODO: Nim bug?
    prc.addPragma(newColonExpr(ident "stackTrace", ident "off"))

  # The proc itself can't raise
  let emptyRaises =
    when (NimMajor, NimMinor) < (1, 4):
      nnkBracket.newTree(newIdentNode("Defect"))
    else:
      nnkBracket.newTree()
  prc.addPragma(nnkExprColonExpr.newTree(
    newIdentNode("raises"),
    emptyRaises))

  # See **Remark 435** in this file.
  # https://github.com/nim-lang/RFCs/issues/435
  prc.addPragma(newIdentNode("gcsafe"))
  result = prc

  if procBody.kind != nnkEmpty:
    result.body = outerProcBody
  #echo(treeRepr(result))
  #if prcName == "recvLineInto":
  #  echo(toStrLit(result))

macro checkFutureExceptions(f, typ: typed): untyped =
  # For RaiseTrackingFuture[void, (ValueError, OSError), will do:
  # if isNil(f.error): discard
  # elif f.error of type CancelledError: raise cast[ref CancelledError](f.error)
  # elif f.error of type ValueError: raise cast[ref ValueError](f.error)
  # elif f.error of type OSError: raise cast[ref OSError](f.error)
  # else: raiseAssert("Unhandled future exception: " & f.error.msg)
  #
  # In future nim versions, this could simply be
  # {.cast(raises: [ValueError, OSError]).}:
  #   raise f.error
  let e = getTypeInst(typ)[2]
  let types = getType(e)

  if types.eqIdent("void"):
    return quote do:
      if not(isNil(`f`.error)):
        if `f`.error of type CancelledError:
          raise cast[ref CancelledError](`f`.error)
        else:
          raiseAssert("Unhandled future exception: " & `f`.error.msg)

  expectKind(types, nnkBracketExpr)
  expectKind(types[0], nnkSym)
  assert types[0].strVal == "tuple"
  assert types.len > 1

  result = nnkIfExpr.newTree(
    nnkElifExpr.newTree(
      quote do: isNil(`f`.error),
      quote do: discard
    )
  )

  result.add nnkElifExpr.newTree(
    quote do: `f`.error of type CancelledError,
    nnkRaiseStmt.newNimNode(lineInfoFrom=typ).add(
      quote do: cast[ref CancelledError](`f`.error)
    )
  )
  for errorType in types[1..^1]:
    result.add nnkElifExpr.newTree(
      quote do: `f`.error of type `errorType`,
      nnkRaiseStmt.newNimNode(lineInfoFrom=typ).add(
        quote do: cast[ref `errorType`](`f`.error)
      )
    )

  result.add nnkElseExpr.newTree(
    quote do: raiseAssert("Unhandled future exception: " & `f`.error.msg)
  )

template await*[T](f: Future[T]): untyped =
  when declared(chronosInternalRetFuture):
    #work around https://github.com/nim-lang/Nim/issues/19193
    when not declaredInScope(chronosInternalTmpFuture):
      var chronosInternalTmpFuture {.inject.}: FutureBase = f
    else:
      chronosInternalTmpFuture = f

    chronosInternalRetFuture.child = chronosInternalTmpFuture

    # This "yield" is meant for a closure iterator in the caller.
    yield chronosInternalTmpFuture

    # By the time we get control back here, we're guaranteed that the Future we
    # just yielded has been completed (success, failure or cancellation),
    # through a very complicated mechanism in which the caller proc (a regular
    # closure) adds itself as a callback to chronosInternalTmpFuture.
    #
    # Callbacks are called only after completion and a copy of the closure
    # iterator that calls this template is still in that callback's closure
    # environment. That's where control actually gets back to us.

    chronosInternalRetFuture.child = nil
    if chronosInternalRetFuture.mustCancel:
      raise newCancelledError()
    when f is RaiseTrackingFuture:
      checkFutureExceptions(chronosInternalTmpFuture, f)
    else:
      chronosInternalTmpFuture.internalCheckComplete()
    when T isnot void:
      cast[type(f)](chronosInternalTmpFuture).internalRead()
  else:
    unsupported "await is only available within {.async.}"

template awaitne*[T](f: Future[T]): Future[T] =
  when declared(chronosInternalRetFuture):
    #work around https://github.com/nim-lang/Nim/issues/19193
    when not declaredInScope(chronosInternalTmpFuture):
      var chronosInternalTmpFuture {.inject.}: FutureBase = f
    else:
      chronosInternalTmpFuture = f
    chronosInternalRetFuture.child = chronosInternalTmpFuture
    yield chronosInternalTmpFuture
    chronosInternalRetFuture.child = nil
    if chronosInternalRetFuture.mustCancel:
      raise newCancelledError()
    cast[type(f)](chronosInternalTmpFuture)
  else:
    unsupported "awaitne is only available within {.async.}"

proc asyncMultipleProcs(
  prc, raises: NimNode,
  trackExceptions: bool): NimNode {.compileTime.} =
  if prc.kind == nnkStmtList:
    for oneProc in prc:
      result = newStmtList()
      result.add asyncSingleProc(oneProc, raises, trackExceptions)
  else:
    result = asyncSingleProc(prc, raises, trackExceptions)
  when defined(nimDumpAsync):
    echo repr result

macro async*(prc: untyped): untyped =
  ## Macro which processes async procedures into the appropriate
  ## iterators and yield statements.

  const defaultException =
    when defined(chronosStrictException): "CatchableError"
    else: "Exception"
  let possibleExceptions = nnkBracket.newTree(newIdentNode(defaultException))
  asyncMultipleProcs(prc, possibleExceptions, false)

macro asyncraises*(possibleExceptions, prc: untyped): untyped =
  asyncMultipleProcs(prc, possibleExceptions, true)

template asyncraises*(prc: untyped): untyped =
  {.error: "Use .asyncraises: [].".}
