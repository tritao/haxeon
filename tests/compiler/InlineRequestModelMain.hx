import compiler.Provides.ProviderOperation;
import compiler.Provides.ProviderOperations;
import compiler.ir.Ir;
import compiler.ir.IrBuilder;
import compiler.ir.IrEnumTagLowering;
import compiler.ir.IrFunction;
import compiler.ir.IrFunction.IrRetention;
import compiler.ir.IrInlineEnumEscapes;
import compiler.ir.IrInlineEnumLayout;
import compiler.ir.IrInlineEnumRequests;
import compiler.ir.IrObjectTable;
import compiler.ir.IrProviders;
import compiler.ir.TypeKey;

class InlineRequestModelMain {
 static function main():Void {
  var logical:IrType = Enum("Payload"), tag:IrType = EnumTag("Tag");
  var mappings:Array<{op:IrIntrinsic, subject:IrType, expected:ProviderOperation}> = [
   {op: EnumDynamicBox(logical), subject: logical, expected: ProviderOperation.BoxDynamic},
   {op: EnumDynamicView(logical), subject: logical, expected: ProviderOperation.ViewDynamic},
   {op: EnumTagBox(tag), subject: tag, expected: ProviderOperation.EnumTagBox},
   {op: EnumTagUnbox(tag), subject: tag, expected: ProviderOperation.EnumTagUnbox},
   {op: InlineEnumBox(logical), subject: logical, expected: ProviderOperations.detailed(ProviderOperation.InlineEnumHelper, "box")},
   {op: InlineEnumUnbox(logical), subject: logical, expected: ProviderOperations.detailed(ProviderOperation.InlineEnumHelper, "unbox")}
  ];
  for (entry in mappings) {
   var row = IrProviders.typedOperation(entry.op);
   if (row == null || row.subject.toString() != TypeKey.of(entry.subject).toString() || row.operation != entry.expected)
    throw 'Incorrect typed provider request: ${entry.op}';
  }
  var declaration:IrEnum = {name: "Payload", cases: [{name: "Value", params: [I32]}]},
   planner = new IrInlineEnumLayout([declaration], [], 64, HashLink), shape = planner.shape("Payload");
  if (shape == null) throw "Expected inline enum layout";
  var program = new IrProgram("main");
  program.objects = planner.generatedObjects();
  program.enums = [{name: declaration.name, cases: declaration.cases, inlineStorage: shape.valueObject.name}];
  var objects = IrObjectTable.of([for (object in program.objects) object.name => object]);
  // The bridge must request both conversions itself, before any escape pass scans the program.
  var factory = new compiler.ir.IrValueArrayFactory(objects, logical, 64, HashLink, 0, program.enums);
  var bridgeBoxes = 0, bridgeUnboxes = 0;
  for (fn in factory.bridge.functions()) for (block in fn.blocks) for (located in block.instructions) switch located.value {
   case Intrinsic(out, InlineEnumBox(Enum("Payload")), arguments):
    if (arguments.length != 1 || !compiler.ir.IrVerifier.sameType(arguments[0].type, Obj(shape.valueObject.name))
        || !compiler.ir.IrVerifier.sameType(out.type, Dyn)) throw "Incorrect value-array box request";
    bridgeBoxes++;
   case Intrinsic(out, InlineEnumUnbox(Enum("Payload")), arguments):
    if (arguments.length != 1 || !compiler.ir.IrVerifier.sameType(arguments[0].type, Dyn)
        || !compiler.ir.IrVerifier.sameType(out.type, Obj(shape.valueObject.name))) throw "Incorrect value-array unbox request";
    bridgeUnboxes++;
   default:
  }
  if (bridgeBoxes != 1 || bridgeUnboxes != 1) throw 'Expected one typed request per array bridge, got $bridgeBoxes/$bridgeUnboxes';
  // Late Wasm varargs adapters must request enum conversions before escape resolution too.
  for (valueType in [Obj(shape.valueObject.name), EnumTag("Tag")]) {
   var signature:IrType = Function([valueType], valueType);
   var adapter = compiler.backend.wasm.WasmDynamicCalls.varargsAdapter("varargs-test", signature, program.enums);
   var boxes = 0, unboxes = 0;
   for (block in adapter.blocks) for (located in block.instructions) switch located.value {
    case Intrinsic(_, InlineEnumBox(Enum("Payload")), _) | Intrinsic(_, EnumTagBox(EnumTag("Tag")), _): boxes++;
    case Intrinsic(_, InlineEnumUnbox(Enum("Payload")), _) | Intrinsic(_, EnumTagUnbox(EnumTag("Tag")), _): unboxes++;
    default:
   }
   if (boxes != 1 || unboxes != 1) throw 'Expected typed varargs requests for $valueType, got $boxes/$unboxes';
  }
  // A late Wasm32 closure cast adapts Dynamic arguments/results to the physical inline layout.
  var closureProgram = new IrProgram("closure-main");
  closureProgram.enums = program.enums;
  closureProgram.objects = program.objects;
  var physical:IrType = Obj(shape.valueObject.name), sourceSignature:IrType = Function([physical], physical),
   targetSignature:IrType = Function([Dyn], Dyn);
  var sourceBuilder = new IrBuilder(), sourceValue = sourceBuilder.argument("value", physical);
  sourceBuilder.returnValue(sourceValue);
  var closureBuilder = new IrBuilder(), sourceClosure = closureBuilder.staticClosure("closure-source", sourceSignature),
   targetClosure = closureBuilder.safeCast(closureBuilder.toDyn(sourceClosure), targetSignature);
  closureBuilder.returnValue(targetClosure);
  closureProgram.functions = [new IrFunction("closure-main", closureBuilder.arguments, targetSignature, closureBuilder.blocks, Ordinary),
   new IrFunction("closure-source", sourceBuilder.arguments, physical, sourceBuilder.blocks, Ordinary)];
  compiler.backend.wasm.linear.WasmLinearClosureAdapters.generate(closureProgram, [], "closure-main", []);
  var closureBoxes = 0, closureUnboxes = 0;
  for (fn in closureProgram.functions) switch fn.kind {
   case ClosureAdapter(_, _):
    for (block in fn.blocks) for (located in block.instructions) switch located.value {
     case Intrinsic(_, InlineEnumBox(Enum("Payload")), _): closureBoxes++;
     case Intrinsic(_, InlineEnumUnbox(Enum("Payload")), _): closureUnboxes++;
     default:
    }
   default:
  }
  if (closureBoxes == 0 || closureUnboxes == 0) throw 'Missing typed closure adapter requests: $closureBoxes/$closureUnboxes';
  // HashLink scalar closure erasure/restoration must introduce the same typed requests.
  var hlProgram = new IrProgram("hl-main");
  hlProgram.enums = program.enums;
  hlProgram.objects = program.objects;
  var hlSource = new IrBuilder(), hlValue = hlSource.argument("value", physical);
  hlSource.returnValue(hlValue);
  var hlMain = new IrBuilder(), hlClosure = hlMain.staticClosure("hl-source", sourceSignature);
  hlMain.returnValue(hlMain.toDyn(hlClosure));
  hlProgram.functions = [new IrFunction("hl-main", hlMain.arguments, Dyn, hlMain.blocks, Ordinary),
   new IrFunction("hl-source", hlSource.arguments, physical, hlSource.blocks, Ordinary)];
  compiler.ir.IrScalarArguments.rewrite(hlProgram);
  compiler.ir.IrScalarClosures.rewrite(hlProgram);
  var hlBoxes = 0, hlUnboxes = 0;
  for (fn in hlProgram.functions) for (block in fn.blocks) for (located in block.instructions) switch located.value {
   case Intrinsic(_, InlineEnumBox(Enum("Payload")), _): hlBoxes++;
   case Intrinsic(_, InlineEnumUnbox(Enum("Payload")), _): hlUnboxes++;
   default:
  }
  if (hlBoxes == 0 || hlUnboxes == 0) throw 'Missing typed HashLink scalar closure requests: $hlBoxes/$hlUnboxes';
  var generated = IrInlineEnumEscapes.functions(program.enums, objects, planner);
  if (generated.length != 2) throw "Expected both inline enum providers";
  var boxProvider = generated[0], unboxProvider = generated[1];
  boxProvider = new IrFunction("opaque_box", boxProvider.arguments, boxProvider.result, boxProvider.blocks, boxProvider.kind,
   boxProvider.debugBindings, boxProvider.inlineHint, boxProvider.retention);
  unboxProvider = new IrFunction("opaque_unbox", unboxProvider.arguments, unboxProvider.result, unboxProvider.blocks, unboxProvider.kind,
   unboxProvider.debugBindings, unboxProvider.inlineHint, unboxProvider.retention);
  // The Wasm scalar-closure pass resolves its generated requests at its existing boundary.
  var wasmProgram = new IrProgram("wasm-main");
  wasmProgram.enums = program.enums;
  wasmProgram.objects = program.objects;
  var wasmSource = new IrBuilder(), wasmValue = wasmSource.argument("value", physical);
  wasmSource.returnValue(wasmValue);
  var wasmMain = new IrBuilder(), wasmClosure = wasmMain.staticClosure("wasm-source", sourceSignature);
  wasmMain.returnValue(wasmMain.toDyn(wasmClosure));
  wasmProgram.functions = [new IrFunction("wasm-main", wasmMain.arguments, Dyn, wasmMain.blocks, Ordinary),
   new IrFunction("wasm-source", wasmSource.arguments, physical, wasmSource.blocks, Ordinary), boxProvider, unboxProvider];
  var wasmResult = compiler.backend.wasm.WasmScalarClosureEscapes.rewrite(wasmProgram, [], [], []);
  var wasmBoxes = 0, wasmUnboxes = 0;
  for (fn in wasmResult.functions) for (block in fn.blocks) for (located in block.instructions) switch located.value {
   case Call(_, "opaque_box", _): wasmBoxes++;
   case Call(_, "opaque_unbox", _): wasmUnboxes++;
   default:
  }
  if (wasmBoxes == 0 || wasmUnboxes == 0) throw 'Wasm scalar closure did not resolve its declared providers: $wasmBoxes/$wasmUnboxes';
  compiler.ir.IrVerifier.verifyInlineEnumsLowered(wasmResult);
  var box = new IrBuilder(), value = box.argument("value", Obj(shape.valueObject.name));
  box.returnValue(box.intrinsic(InlineEnumBox(logical), [value], Dyn));
  var unbox = new IrBuilder(), dynamicValue = unbox.argument("value", Dyn);
  unbox.returnValue(unbox.intrinsic(InlineEnumUnbox(logical), [dynamicValue], Obj(shape.valueObject.name)));
  program.functions = [new IrFunction("main", box.arguments, Dyn, box.blocks, GeneratedHelper,
   [{identity: "input", name: "value", value: value, path: "fixture.hx", scopeStart: 0, scopeEnd: 1}], true, Keep),
   new IrFunction("unbox", unbox.arguments, Obj(shape.valueObject.name), unbox.blocks, Ordinary), boxProvider, unboxProvider];
  var originalLocated = program.functions[0].blocks[0].instructions[0];
  var provenance = compiler.ir.SourceProvenance.user(new compiler.Source.SourceFile("fixture.hx", "x").span(0, 1));
  program.functions[0].blocks[0].instructions[0] = new compiler.ir.SourceProvenance.Located(originalLocated.value, provenance);
  var originalTerminator = program.functions[0].blocks[0].terminator;
  for (fn in [program.functions[0], program.functions[1]]) {
   var unresolvedRejected = false;
   try compiler.ir.IrVerifier.verifyResolvedEnumOperations([fn]) catch (error:String) {
    if (error.indexOf("unresolved typed enum conversion") < 0) throw error;
    unresolvedRejected = true;
   }
   if (!unresolvedRejected) throw "Unresolved inline enum conversion passed the producer boundary";
  }
  var restored = compiler.ir.codec.CanonicalIrCodec.decode(compiler.ir.codec.CanonicalIrCodec.encode(program));
  var restoredMain = compiler.ir.codec.IrFunctionStateCodec.decode(compiler.ir.codec.IrFunctionStateCodec.encode(program.functions[0]));
  for (fn in [restored.functions[0], restoredMain]) switch fn.blocks[0].instructions[0].value {
   case Intrinsic(_, InlineEnumBox(Enum("Payload")), arguments) if (arguments.length == 1):
   default: throw "Typed inline-enum request did not survive IR codec roundtrip";
  }
  var restoredUnbox = compiler.ir.codec.IrFunctionStateCodec.decode(compiler.ir.codec.IrFunctionStateCodec.encode(program.functions[1]));
  for (fn in [restored.functions[1], restoredUnbox]) switch fn.blocks[0].instructions[0].value {
   case Intrinsic(_, InlineEnumUnbox(Enum("Payload")), arguments) if (arguments.length == 1):
   default: throw "Typed inline-enum unbox did not survive IR codec roundtrip";
  }
  var restoredProblem = IrProviders.checkTypedOperations(restored.functions);
  if (restoredProblem != null) throw 'Restored enum requests lost their providers: $restoredProblem';
  var providerProblem = IrProviders.checkTypedOperations(program.functions);
  if (providerProblem != null) throw 'Valid enum requests lost their declared providers: $providerProblem';
  var originalMain = program.functions[0], originalProvider = program.functions[2];
  var unchanged = [boxProvider, unboxProvider];
  if (IrInlineEnumRequests.resolve(program, unchanged) != unchanged) throw "A no-op request resolution allocated a replacement";
  IrEnumTagLowering.escapes(program);
  if (program.functions[0] == originalMain || program.functions[2] != originalProvider
      || !program.functions[0].inlineHint || program.functions[0].retention != Keep
      || program.functions[0].debugBindings.length != 1 || program.functions[0].debugBindings[0].identity != "input")
   throw "Request resolution lost copy identity or metadata";
  switch program.functions[0].kind { case GeneratedHelper: default: throw "Request resolution lost the function kind"; }
  if (program.functions[0].blocks[0].instructions[0].provenance != provenance
      || program.functions[0].blocks[0].terminator != originalTerminator)
   throw "Request resolution lost instruction provenance or terminator identity";
  switch originalMain.blocks[0].instructions[0].value {
   case Intrinsic(_, InlineEnumBox(_), _):
   default: throw "Request resolution mutated the original function";
  }
  var calls:Array<String> = [];
  for (fn in program.functions.slice(0, 2)) for (block in fn.blocks) for (instruction in block.instructions)
   switch instruction.value { case Call(_, name, _): calls.push(name); default: }
  if (calls.join(",") != "opaque_box,opaque_unbox") throw 'Wrong resolved providers: $calls';
  compiler.ir.IrVerifier.verifyInlineEnumsLowered(program);
  var impostor = program.copy(), originalBox = program.functions[2];
  impostor.functions = [program.functions[0], new IrFunction(IrInlineEnumEscapes.boxName("Payload"), originalBox.arguments, originalBox.result,
   originalBox.blocks, GeneratedHelper, originalBox.debugBindings, originalBox.inlineHint, originalBox.retention)];
  var rejectedImpostor = false;
  try compiler.ir.IrVerifier.verifyInlineEnumsLowered(impostor) catch (error:String) {
   if (error.indexOf('IR inline enum "Payload" retains nominal value storage') < 0) throw error;
   rejectedImpostor = true;
  }
  if (!rejectedImpostor) throw "A helper name without the declared provider role bypassed verification";
  var missing = new IrProgram("main"), missingBuilder = new IrBuilder(), missingValue = missingBuilder.argument("value", Obj(shape.valueObject.name));
  missing.objects = program.objects; missing.enums = program.enums;
  missingBuilder.returnValue(missingBuilder.intrinsic(InlineEnumBox(logical), [missingValue], Dyn));
  var missingMain = new IrFunction("main", missingBuilder.arguments, Dyn, missingBuilder.blocks, Ordinary);
  var missingUnbox = new IrBuilder(), missingDynamic = missingUnbox.argument("value", Dyn);
  missingUnbox.returnValue(missingUnbox.intrinsic(InlineEnumUnbox(logical), [missingDynamic], Obj(shape.valueObject.name)));
  missing.functions = [missingMain, new IrFunction("missingUnbox", missingUnbox.arguments, Obj(shape.valueObject.name), missingUnbox.blocks, Ordinary), boxProvider];
  var missingProblem = IrProviders.checkTypedOperations(missing.functions);
  if (missingProblem == null || missingProblem.indexOf(ProviderOperations.detailed(ProviderOperation.InlineEnumHelper, "unbox")) < 0)
   throw 'The missing unbox provider was not identified: $missingProblem';
  var rejected = false;
  try IrEnumTagLowering.escapes(missing) catch (error:String) {
   if (error.indexOf("Missing inline enum provider") < 0) throw error;
   rejected = true;
  }
  if (!rejected) throw "Missing inline enum provider was accepted";
  if (missing.functions[0] != missingMain) throw "A failed request pass published a partial rewrite";
  switch missingMain.blocks[0].instructions[0].value {
   case Intrinsic(_, InlineEnumBox(_), _):
   default: throw "A failed request pass mutated its input";
  }
  var malformed = new IrProgram("main"), malformedBuilder = new IrBuilder(), wrong = malformedBuilder.argument("value", I32);
  malformed.objects = program.objects; malformed.enums = program.enums;
  malformedBuilder.returnValue(malformedBuilder.intrinsic(InlineEnumBox(logical), [wrong], Dyn));
  malformed.functions = [new IrFunction("main", malformedBuilder.arguments, Dyn, malformedBuilder.blocks, Ordinary), boxProvider];
  rejected = false;
  try IrEnumTagLowering.escapes(malformed) catch (error:String) {
   if (error.indexOf("Invalid inline enum box request signature") < 0) throw error;
   rejected = true;
  }
  if (!rejected) throw "Malformed inline enum request was accepted";
  var badProviderProgram = new IrProgram("main"), badRequest = new IrBuilder(), requestValue = badRequest.argument("value", Obj(shape.valueObject.name));
  badProviderProgram.objects = program.objects; badProviderProgram.enums = program.enums;
  badRequest.returnValue(badRequest.intrinsic(InlineEnumBox(logical), [requestValue], Dyn));
  var badProvider = new IrBuilder(), badArgument = badProvider.argument("value", I32);
  badProvider.returnValue(badProvider.toDyn(badArgument));
  badProviderProgram.functions = [new IrFunction("main", badRequest.arguments, Dyn, badRequest.blocks, Ordinary),
   new IrFunction("provider_with_wrong_signature", badProvider.arguments, Dyn, badProvider.blocks, boxProvider.kind)];
  rejected = false;
  try IrEnumTagLowering.escapes(badProviderProgram) catch (error:String) {
   if (error.indexOf("Invalid inline enum provider signature") < 0) throw error;
   rejected = true;
  }
  if (!rejected) throw "Invalid inline enum provider signature was accepted";
  var other:IrEnum = {name: "OtherPayload", cases: [{name: "Value", params: [I32]}]},
   nominalPlanner = new IrInlineEnumLayout([declaration, other], [], 64, HashLink),
   firstNominal = nominalPlanner.shape("Payload"), secondNominal = nominalPlanner.shape("OtherPayload");
  if (firstNominal == null || secondNominal == null) throw "Expected nominal inline enum fixtures";
  var nominal = new IrProgram("main");
  nominal.objects = nominalPlanner.generatedObjects();
  nominal.enums = [{name: declaration.name, cases: declaration.cases, inlineStorage: firstNominal.valueObject.name},
   {name: other.name, cases: other.cases, inlineStorage: secondNominal.valueObject.name}];
  var nominalObjects = IrObjectTable.of([for (object in nominal.objects) object.name => object]);
  var nominalProviders = IrInlineEnumEscapes.functions(nominal.enums, nominalObjects, nominalPlanner);
  var expectedName:Null<String> = null;
  for (fn in nominalProviders) switch fn.kind {
   case Provider(subject, operation) if (subject.toString() == TypeKey.of(Enum("OtherPayload")).toString()
      && operation == ProviderOperations.detailed(ProviderOperation.InlineEnumHelper, "box")): expectedName = fn.name;
   default:
  }
  if (expectedName == null) throw "Missing second nominal enum provider";
  var nominalBuilder = new IrBuilder(), secondValue = nominalBuilder.argument("value", Obj(secondNominal.valueObject.name));
  nominalBuilder.returnValue(nominalBuilder.intrinsic(InlineEnumBox(Enum("OtherPayload")), [secondValue], Dyn));
  nominal.functions = [new IrFunction("main", nominalBuilder.arguments, Dyn, nominalBuilder.blocks, Ordinary)].concat(nominalProviders);
  IrEnumTagLowering.escapes(nominal);
  switch nominal.functions[0].blocks[0].instructions[0].value {
   case Call(_, name, _) if (name == expectedName):
   default: throw "Inline enum request selected a provider for the wrong nominal enum";
  }
  Sys.println("PASS: typed enum requests select declared providers even without tag enums or encoded linkage names");
 }
}
