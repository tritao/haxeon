import compiler.Frontend;
import compiler.backend.Backend.BackendTarget;
import compiler.backend.hl.HlBackend;
import compiler.backend.wasm.WasmBackend;
import compiler.backend.wasm.WasmTarget;
import compiler.backend.wasm.WasmTarget.WasmReferenceModel;
import compiler.backend.wasm.WasmLayout;
import compiler.backend.wasm.WasmGcTypePlan;
import compiler.backend.wasm.WasmCfgAnalysis;
import compiler.backend.wasm.WasmRuntimeAbi;
import compiler.backend.wasm.WasmGcRoots;
import compiler.backend.wasm.WasmStructurer;
import compiler.backend.wasm.WasmPatch;
import compiler.backend.wasm.WasmEncoder;
import compiler.backend.wasm.WasmValidator;
import compiler.backend.wasm.WasmModule.WasmModule;
import compiler.backend.wasm.WasmModule.WasmFunction;
import compiler.backend.wasm.WasmTypes.WasmValueType;
import compiler.backend.wasm.WasmTypes.WasmInstruction;
import compiler.backend.wasm.WasmTypes.WasmFunctionType;
import compiler.backend.wasm.WasmTypes.WasmHeapType;
import compiler.backend.wasm.WasmTypes.WasmStorageType;
import compiler.backend.wasm.WasmTypes.WasmCompositeType;
import compiler.backend.wasm.WasmTypes.WasmSubtype;
import compiler.abi.PatchPlanner.PatchDecision;
import compiler.ir.IrInterpreter;
import compiler.ir.codec.CanonicalIrCodec;
import compiler.ir.IrBuilder;
import compiler.ir.IrFunction;
import compiler.ir.Ir.IrInstruction;
import compiler.ir.Ir.IrTerminator;
import compiler.ir.Ir.IrBlock;
import compiler.ir.Ir.IrProgram;
import compiler.ir.Ir.IrType;
import compiler.ir.Ir.IrValue;
import compiler.ir.SourceProvenance;
import compiler.ir.SourceProvenance.Located;
import sys.io.File;

class WasmBackendMain {
	static function main():Void {
		if (WasmTarget.forBackend(Wasm32).referenceModel != Linear32)
			throw "Wasm32 must use the linear32 reference model";
		var hl = new HlBackend().compile(Frontend.compile("function main():Int return 42;"), {target: HashLink, debugNames: true});
		if (hl.bytes.get(0) != 72 || hl.bytes.get(1) != 76 || hl.bytes.get(2) != 66)
			throw "The target-neutral backend seam must preserve the HashLink backend";
		var layout = new WasmLayout(Frontend.compile("class Box { public var value:Int; public function new() {} } function main():Int return 0;"));
		if (layout.object("Box").fields[0].offset != WasmLayout.HEADER_SIZE)
			throw "Wasm object fields must use the centralized layout";
		var runtimeOps = WasmRuntimeAbi.operations(Frontend.compile("function main():Int { var value = 40; return value + 2; }"));
		if (runtimeOps.length != 0)
			throw "Scalar Wasm IR should not require runtime operations";
		if (WasmGcRoots.analyze(Frontend.compile("function main():Int return 42;").functions[0]).length != 0)
			throw "Scalar functions should not have managed GC roots";
		var boxingProgram = Frontend.compile("class Marker { public function new() {} } function main():Int { var marker = new Marker(); var boxed:Dynamic = 1; return boxed == 1 && marker != null ? 42 : 0; }");
		var boxingFunction:Null<IrFunction> = null;
		for (fn in boxingProgram.functions)
			if (fn.name == "main")
				boxingFunction = fn;
		if (boxingFunction == null)
			throw "Primitive boxing fixture is missing its entry function";
		var markerValue:Null<Int> = null;
		for (block in boxingFunction.blocks)
			for (instruction in block.instructions)
				switch instruction.value {
					case NewObject(output, "Marker"):
						markerValue = output.id;
					default:
				}
		var rootsBoxingSafepoint = false;
		for (point in WasmGcRoots.analyze(boxingFunction))
			for (block in boxingFunction.blocks)
				if (block.id == point.block && point.instruction < block.instructions.length)
					switch block.instructions[point.instruction].value {
						case ToDyn(_, value) if (value.type == I32
							&& markerValue != null
							&& point.liveReferences.indexOf(markerValue) >= 0):
							rootsBoxingSafepoint = true;
						default:
					}
		if (!rootsBoxingSafepoint)
			throw "Primitive ToDyn allocation must be a safepoint that retains live managed references";
		var manyRootsBuilder = new IrBuilder(),
			manyRootArguments:Array<IrValue> = [];
		for (index in 0...40)
			manyRootArguments.push(manyRootsBuilder.argument('root$index', Obj("Marker")));
		manyRootsBuilder.call("root_safepoint", manyRootArguments, Void);
		manyRootsBuilder.returnValue(manyRootsBuilder.constInt(0));
		var manyRootsFunction = new IrFunction("manyRoots", manyRootsBuilder.arguments, I32, manyRootsBuilder.blocks),
			manyLiveReferences:Array<Int> = [];
		for (point in WasmGcRoots.analyze(manyRootsFunction))
			if (point.block == 0 && point.instruction == 0)
				manyLiveReferences = point.liveReferences;
		if (manyLiveReferences.length != manyRootArguments.length)
			throw "Wasm GC-root bitsets lost references across a word boundary";
		for (index in 0...manyRootArguments.length)
			if (manyLiveReferences[index] != manyRootArguments[index].id)
				throw "Wasm GC-root bitsets did not preserve deterministic reference ordering";
		var referenceProgram = Frontend.compile("function sum(value:Int):Int { var result = 0; while (value > 0) { result = result + value; value = value - 1; } return result; } function main():Int return sum(3);");
		var visitedRootFunctions:Array<String> = [];
		var streamedRoots = WasmGcRoots.encodeAndVisit(referenceProgram, function(fn, _) visitedRootFunctions.push(fn.name));
		if (streamedRoots.compare(WasmGcRoots.encode(referenceProgram)) != 0
			|| visitedRootFunctions.length != referenceProgram.functions.length)
			throw "Streaming Wasm GC-root analysis changed canonical metadata or skipped a function";
		if (new IrInterpreter(referenceProgram).run("main") != 6)
			throw "The SSA reference interpreter disagrees with canonical IR semantics";
		var entryLoopBuilder = new IrBuilder(),
			entryLoopCondition = entryLoopBuilder.argument("continue", Bool),
			entryBlock = entryLoopBuilder.currentBlock(),
			entryLoopBody = entryLoopBuilder.createBlock(),
			entryLoopExit = entryLoopBuilder.createBlock();
		entryLoopBuilder.branch(entryLoopCondition, entryLoopBody, entryLoopExit);
		entryLoopBuilder.select(entryLoopBody);
		entryLoopBuilder.jump(entryBlock);
		entryLoopBuilder.select(entryLoopExit);
		entryLoopBuilder.returnValue(entryLoopBuilder.constInt(0));
		var entryLoop = new IrFunction("entryLoop", entryLoopBuilder.arguments, I32, entryLoopBuilder.blocks),
			entryLoopStructurer = new WasmStructurer(entryLoop);
		if (!entryLoopStructurer.analysis.reducible || !entryLoopStructurer.canUseStructured())
			throw "An entry-rooted single-header loop must remain reducible and structurably emitted";
		var diamondBuilder = new IrBuilder(),
			diamondCondition = diamondBuilder.argument("condition", Bool),
			diamondEntry = diamondBuilder.currentBlock().id,
			diamondLeft = diamondBuilder.createBlock(),
			diamondRight = diamondBuilder.createBlock(),
			diamondMerge = diamondBuilder.createBlock();
		diamondBuilder.branch(diamondCondition, diamondLeft, diamondRight);
		diamondBuilder.select(diamondLeft);
		diamondBuilder.jump(diamondMerge);
		diamondBuilder.select(diamondRight);
		diamondBuilder.jump(diamondMerge);
		diamondBuilder.select(diamondMerge);
		diamondBuilder.returnValue(diamondBuilder.constInt(42));
		var diamondAnalysis = new WasmCfgAnalysis(new IrFunction("diamond", diamondBuilder.arguments, I32, diamondBuilder.blocks));
		if (diamondAnalysis.postImmediate.get(diamondEntry) != diamondMerge.id
			|| diamondAnalysis.postImmediate.get(diamondLeft.id) != diamondMerge.id
			|| diamondAnalysis.postImmediate.get(diamondRight.id) != diamondMerge.id
			|| diamondAnalysis.mergeFor(diamondLeft.id, diamondRight.id) != diamondMerge.id)
			throw "Bitset post-dominators must preserve the nearest common merge for a diamond CFG";
		var exitsBuilder = new IrBuilder(),
			exitsCondition = exitsBuilder.argument("condition", Bool),
			exitsEntry = exitsBuilder.currentBlock().id,
			exitsLeft = exitsBuilder.createBlock(),
			exitsRight = exitsBuilder.createBlock();
		exitsBuilder.branch(exitsCondition, exitsLeft, exitsRight);
		exitsBuilder.select(exitsLeft);
		exitsBuilder.returnValue(exitsBuilder.constInt(1));
		exitsBuilder.select(exitsRight);
		exitsBuilder.returnValue(exitsBuilder.constInt(2));
		var exitsAnalysis = new WasmCfgAnalysis(new IrFunction("multipleExits", exitsBuilder.arguments, I32, exitsBuilder.blocks));
		if (exitsAnalysis.postImmediate.get(exitsEntry) != exitsEntry || exitsAnalysis.mergeFor(exitsLeft.id, exitsRight.id) != null)
			throw "Post-dominators must not invent a shared merge for distinct function exits";
		var canonical = CanonicalIrCodec.decode(CanonicalIrCodec.encode(referenceProgram));
		if (new IrInterpreter(canonical).run("main") != 6)
			throw "Canonical Haxeon IR did not round-trip through its versioned codec";
		if (WasmPatch.manifest(referenceProgram).length == 0 || WasmPatch.plan(referenceProgram, canonical) != Patch)
			throw "Wasm patch metadata must preserve a compatible semantic ABI";
		var patchArtifact = new WasmBackend().compilePatch(referenceProgram, canonical, ["main"], {target: Wasm32, debugNames: true});
		var patchEntries = WasmPatch.readManifest(patchArtifact.manifest);
		if (patchArtifact.bytes.length < 8 || patchEntries.length != 1 || patchEntries[0].name != "main" || patchArtifact.changed.length != 1)
			throw "Wasm patch compilation must produce a validated replacement artifact";
		var objectBytes = objectProgram();
		if (new IrInterpreter(Frontend.compile("class Box { public var value:Int; public function new() {} } function main():Int { var box = new Box(); box.value = 42; return box.value; }"))
			.run("main") != 42)
			throw "The SSA interpreter must execute object field semantics";
		if (new IrInterpreter(Frontend.compile("function main():Int { var values = new Array<Int>(1); values[0] = 42; return values[0]; }")).run("main") != 42)
			throw "The SSA interpreter must execute array semantics";
		var iteratorProgram = Frontend.compile("function main():Int { var values = [20, 22]; var first = values.iterator(); var second = values.iterator(); if (first.next() != 20 || second.next() != 20 || first.next() != 22 || second.next() != 22 || first.hasNext() || second.hasNext()) return 0; return 42; }");
		if (new IrInterpreter(iteratorProgram).run("main") != 42)
			throw "The SSA interpreter must preserve typed iterator cursors and array iteration semantics";
		var canonicalIteratorProgram = CanonicalIrCodec.decode(CanonicalIrCodec.encode(iteratorProgram));
		if (new IrInterpreter(canonicalIteratorProgram).run("main") != 42)
			throw "Canonical IR persistence must preserve generic iterator types and cursor semantics";
		if (new IrInterpreter(Frontend.compile("function fail():Void { throw \"boom\"; } function main():Int { var value = 0; try { fail(); } catch (error:Dynamic) { value = 42; } return value; }"))
			.run("main") != 42)
			throw "The SSA interpreter must execute exception edges";
		if (new IrInterpreter(Frontend.compile("class Base { public var value:Int; public function new() { value = 42; } } class Child extends Base { public function new() { super(); } } function main():Int { var child = new Child(); return child.value; }"))
			.run("main") != 42)
			throw "The SSA interpreter must preserve inherited object fields";
		var first = compile("function main():Int return 40 + 2;");
		var int64FlagsBuilder = new IrBuilder(),
			highWord = int64FlagsBuilder.constInt(-2147483648),
			zeroWord = int64FlagsBuilder.constInt(0),
			lowWord = int64FlagsBuilder.constInt(1),
			highFlag = int64FlagsBuilder.call("haxe.Int64.make", [highWord, zeroWord], I64),
			lowFlag = int64FlagsBuilder.call("haxe.Int64.make", [zeroWord, lowWord], I64),
			shiftCount = int64FlagsBuilder.constInt(32),
			leftShifted = int64FlagsBuilder.call("haxe.Int64.shl", [lowFlag, shiftCount], I64),
			arithmeticShifted = int64FlagsBuilder.call("haxe.Int64.shr", [leftShifted, shiftCount], I64),
			logicalShifted = int64FlagsBuilder.call("haxe.Int64.ushr", [arithmeticShifted, shiftCount], I64),
			combinedFlags = int64FlagsBuilder.call("haxe.Int64.or", [highFlag, lowFlag], I64),
			clearedFlags = int64FlagsBuilder.call("haxe.Int64.xor", [combinedFlags, lowFlag], I64),
			remainingFlags = int64FlagsBuilder.call("haxe.Int64.and", [clearedFlags, highFlag], I64),
			flagsEqual = int64FlagsBuilder.call("haxe.Int64.compare", [remainingFlags, highFlag], I32);
		int64FlagsBuilder.returnValue(flagsEqual);
		var int64FlagsProgram = new IrProgram("main");
		int64FlagsProgram.natives = [
			{
				name: "haxe.Int64.make",
				library: "haxeon_runtime",
				symbol: "__int64_make",
				arguments: [I32, I32],
				result: I64
			},
			{
				name: "haxe.Int64.shl",
				library: "haxeon_runtime",
				symbol: "__int64_shl",
				arguments: [I64, I32],
				result: I64
			},
			{
				name: "haxe.Int64.shr",
				library: "haxeon_runtime",
				symbol: "__int64_shr",
				arguments: [I64, I32],
				result: I64
			},
			{
				name: "haxe.Int64.ushr",
				library: "haxeon_runtime",
				symbol: "__int64_ushr",
				arguments: [I64, I32],
				result: I64
			},
			{
				name: "haxe.Int64.or",
				library: "haxeon_runtime",
				symbol: "__int64_or",
				arguments: [I64, I64],
				result: I64
			},
			{
				name: "haxe.Int64.xor",
				library: "haxeon_runtime",
				symbol: "__int64_xor",
				arguments: [I64, I64],
				result: I64
			},
			{
				name: "haxe.Int64.and",
				library: "haxeon_runtime",
				symbol: "__int64_and",
				arguments: [I64, I64],
				result: I64
			},
			{
				name: "haxe.Int64.compare",
				library: "haxeon_runtime",
				symbol: "__int64_compare",
				arguments: [I64, I64],
				result: I32
			}
		];
		int64FlagsProgram.functions.push(new IrFunction("main", [], I32, int64FlagsBuilder.blocks));
		var int64FlagsWasm = new WasmBackend().compile(int64FlagsProgram, {target: Wasm32, debugNames: true});
		if (int64FlagsWasm.bytes.length < 8 || int64FlagsWasm.bytes.get(0) != 0 || int64FlagsWasm.bytes.get(1) != 97)
			throw "Wasm Int64 flag operations failed to lower into a module";
		var memoryStats = new WasmBackend().compile(Frontend.compile("function main():Int { var values = [1, 2, 3]; return values.length; }"),
			{target: Wasm32, debugNames: true, wasmMemoryStats: true});
		for (name in [
			"haxeon.memory.heap_base",
			"haxeon.memory.heap_top",
			"haxeon.memory.metadata_base",
			"haxeon.memory.metadata_top",
			"haxeon.memory.allocation_count",
			"haxeon.memory.allocated_bytes",
			"haxeon.memory.largest_allocation_bytes",
			"haxeon.memory.collection_count"
		])
			if (!containsBytes(memoryStats.bytes, name))
				throw 'Wasm allocator diagnostics omitted export "$name"';
		var branch = compile("function main():Int { var value:Int; if (true) value = 40; else value = 2; return value + 2; }");
		var loop = compile("function sum(value:Int):Int { var result = 0; while (value > 0) { result = result + value; value = value - 1; } return result; } function main():Int return sum(3);");
		var array = compile("function main():Int { var values = new Array<Int>(1); values[0] = 42; return values[0]; }");
		var floatArray = compile("function main():Int { var values = new Array<Float>(1); values[0] = 40.5; return values[0] == 40.5 ? 42 : 0; }");
		var arrayOps = compile("function main():Int { var first = [40]; var second = [2]; var combined = first.concat(second); return combined[0] + combined[1]; }");
		var arrayMutation = compile("function main():Int { var values = [40]; values.push(2); return values.pop() + values[0]; }");
		var string = compile("function main():Int return \"haxeon\".length;");
		var stringOps = compile("function main():Int return (\"ha\" + \"xeon\" == \"haxeon\") ? 42 : 0;");
		var stdStringProgram = Frontend.compile("function main():Int { var context = \"layoutSession.item(\" + 9001 + \")\"; var minimum = \"\" + (-2147483647 - 1); return (\"\" + 42) == \"42\" && minimum == \"-2147483648\" && (\"\" + true) == \"true\" && (\"\" + false) == \"false\" && (\"\" + null) == \"null\" && context == \"layoutSession.item(9001)\" ? 42 : 0; }");
		stdStringProgram.natives.push({
			name: "__std_string",
			library: "haxeon_runtime",
			symbol: "__std_string",
			arguments: [Dyn],
			result: Bytes
		});
		var stdString = new WasmBackend().compile(stdStringProgram, {target: Wasm32, debugNames: true}).bytes;
		var stdStringInt64 = new WasmBackend().compile(int64StringProgram(), {target: Wasm32, debugNames: true, exports: ["stringifyInt64"]}).bytes;
		var stdStringFloat = new WasmBackend().compile(floatStringProgram(), {target: Wasm32, debugNames: true, exports: ["stringifyFloat"]}).bytes;
		var method = compile("class Counter { public var value:Int; public function new() { value = 40; } public function add(delta:Int):Int return value + delta; } function main():Int { var counter = new Counter(); return counter.add(2); }");
		var global = compile("class State { public static var value:Int = 40; } function main():Int { State.value = State.value + 2; return State.value; }");
		var floatGlobal = compile("class FloatState { public static var value:Float = 40.0; } function main():Int return FloatState.value == 40.0 ? 42 : 0;");
		var enumValue = compile("enum Answer { No; Yes(value:Int); } function main():Int { var answer:Answer = Yes(42); return switch (answer) { case Yes(value): value; case No: 0; }; }");
		var floatEnum = compile("enum Measurement { Value(prefix:Int, value:Float); } function main():Int { var measurement:Measurement = Value(7, 40.5); return switch (measurement) { case Value(prefix, value): prefix + (value == 40.5 ? 35 : 0); }; }");
		var inheritedField = compile("class Base { public var value:Int; public function new() { value = 42; } } class Child extends Base { public function new() { super(); } } function main():Int { var child = new Child(); return child.value; }");
		var largeArray = compile("function main():Int { var values = new Array<Int>(20000); return values.length; }");
		var closure = compile("function increment(value:Int):Int return value + 1; function main():Int { var fn = increment; return fn(41); }");
		var instanceClosure = compile("class Adder { public function new() {} public function add(value:Int):Int return value + 1; } function main():Int { var adder = new Adder(); var fn = adder.add; return fn(41); }");
		var virtualCall = compile("interface Adder { function add(value:Int):Int; } class Concrete implements Adder { public function new() {} public function add(value:Int):Int return value + 1; } function main():Int { var adder:Adder = new Concrete(); return adder.add(41); }");
		File.saveBytes("out/wasm-backend-test.wasm", first);
		File.saveBytes("out/wasm-backend-branch.wasm", branch);
		File.saveBytes("out/wasm-backend-loop.wasm", loop);
		File.saveBytes("out/wasm-backend-object.wasm", objectBytes);
		File.saveBytes("out/wasm-backend-array.wasm", array);
		File.saveBytes("out/wasm-backend-float-array.wasm", floatArray);
		File.saveBytes("out/wasm-backend-array-ops.wasm", arrayOps);
		File.saveBytes("out/wasm-backend-array-mutation.wasm", arrayMutation);
		File.saveBytes("out/wasm-backend-string.wasm", string);
		File.saveBytes("out/wasm-backend-string-ops.wasm", stringOps);
		File.saveBytes("out/wasm-backend-std-string.wasm", stdString);
		File.saveBytes("out/wasm-backend-std-string-i64.wasm", stdStringInt64);
		File.saveBytes("out/wasm-backend-std-string-f64.wasm", stdStringFloat);
		File.saveBytes("out/wasm-backend-method.wasm", method);
		File.saveBytes("out/wasm-backend-global.wasm", global);
		File.saveBytes("out/wasm-backend-float-global.wasm", floatGlobal);
		File.saveBytes("out/wasm-backend-enum.wasm", enumValue);
		File.saveBytes("out/wasm-backend-float-enum.wasm", floatEnum);
		File.saveBytes("out/wasm-backend-inherited-field.wasm", inheritedField);
		File.saveBytes("out/wasm-backend-large-array.wasm", largeArray);
		File.saveBytes("out/wasm-backend-closure.wasm", closure);
		File.saveBytes("out/wasm-backend-instance-closure.wasm", instanceClosure);
		File.saveBytes("out/wasm-backend-virtual.wasm", virtualCall);
		validateGcModelRejectsInvalidModules();
		File.saveBytes("out/wasm-gc-model.wasm", compileGcTypeModel());
		File.saveBytes("out/wasm-gc-type-plan.wasm", compileGcTypePlan());
		File.saveBytes("out/wasm-gc-objects.wasm", compileGcObjectProgram());
		File.saveBytes("out/wasm-gc-arrays.wasm", compileGcArrayProgram());
		File.saveBytes("out/wasm-gc-enums.wasm", compileGcEnumProgram());
		File.saveBytes("out/wasm-gc-closures.wasm", compileGcClosureProgram());
		File.saveBytes("out/wasm-gc-dynamic.wasm", compileGcDynamicProgram());
		Sys.println("PASS: Wasm scalar backend");
	}

	static function compileGcObjectProgram():haxe.io.Bytes {
		var source = File.getContent("tests/programs/wasm-gc-objects.hx"),
			bytes = new WasmBackend().compile(Frontend.compile(source), {target: WasmGc, debugNames: true}).bytes;
		for (forbidden in [
			"__haxeon_alloc",
			"__haxeon_gc_mark",
			"__haxeon_gc_trace",
			"__haxeon_gc_collect",
			"haxeon.gc.roots"
		])
			if (containsBytes(bytes, forbidden))
				throw 'Wasm GC object module unexpectedly contains linear collector metadata "$forbidden"';
		return bytes;
	}

	static function compileGcArrayProgram():haxe.io.Bytes {
		var source = File.getContent("tests/programs/wasm-gc-arrays.hx"),
			bytes = new WasmBackend().compile(Frontend.compile(source), {target: WasmGc, debugNames: true}).bytes;
		for (forbidden in [
			"__haxeon_alloc",
			"__haxeon_gc_mark",
			"__haxeon_gc_trace",
			"__haxeon_gc_collect",
			"haxeon.gc.roots"
		])
			if (containsBytes(bytes, forbidden))
				throw 'Wasm GC array module unexpectedly contains linear collector metadata "$forbidden"';
		return bytes;
	}

	static function compileGcEnumProgram():haxe.io.Bytes {
		var source = File.getContent("tests/programs/wasm-gc-enums.hx"),
			bytes = new WasmBackend().compile(Frontend.compile(source), {target: WasmGc, debugNames: true}).bytes;
		for (forbidden in [
			"__haxeon_alloc",
			"__haxeon_gc_mark",
			"__haxeon_gc_trace",
			"__haxeon_gc_collect",
			"haxeon.gc.roots"
		])
			if (containsBytes(bytes, forbidden))
				throw 'Wasm GC enum module unexpectedly contains linear collector metadata "$forbidden"';
		return bytes;
	}

	static function compileGcClosureProgram():haxe.io.Bytes {
		var source = File.getContent("tests/programs/wasm-gc-closures.hx"),
			bytes = new WasmBackend().compile(Frontend.compile(source), {target: WasmGc, debugNames: true}).bytes;
		for (forbidden in [
			"__haxeon_alloc",
			"__haxeon_gc_mark",
			"__haxeon_gc_trace",
			"__haxeon_gc_collect",
			"haxeon.gc.roots"
		])
			if (containsBytes(bytes, forbidden))
				throw 'Wasm GC closure module unexpectedly contains linear collector metadata "$forbidden"';
		return bytes;
	}

	static function compileGcDynamicProgram():haxe.io.Bytes {
		var source = File.getContent("tests/programs/wasm-gc-dynamic.hx"),
			program = Frontend.compile(source);
		program.natives.push({
			name: "__dynamic_equal",
			library: "haxeon_runtime",
			symbol: "__dynamic_equal",
			arguments: [Dyn, Dyn],
			result: Bool
		});
		var bytes = new WasmBackend().compile(program, {target: WasmGc, debugNames: true}).bytes;
		for (forbidden in [
			"__haxeon_alloc",
			"__haxeon_gc_mark",
			"__haxeon_gc_trace",
			"__haxeon_gc_collect",
			"haxeon.gc.roots"
		])
			if (containsBytes(bytes, forbidden))
				throw 'Wasm GC Dynamic module unexpectedly contains linear collector metadata "$forbidden"';
		return bytes;
	}

	static function compileGcTypePlan():haxe.io.Bytes {
		var program = new IrProgram("main");
		program.interfaces.push({
			name: "Readable",
			bases: [],
			methods: [{name: "read", arguments: [], result: I32}]
		});
		program.objects.push({
			name: "Base",
			isValue: false,
			base: null,
			interfaces: [],
			fields: [{name: "id", type: I32}],
			methods: []
		});
		program.objects.push({
			name: "Node",
			isValue: false,
			base: "Base",
			interfaces: ["Readable"],
			fields: [
				{name: "parent", type: Obj("Node")},
				{name: "children", type: Array(Obj("Node"))}
			],
			methods: []
		});
		program.enums.push({
			name: "Choice",
			cases: [
				{name: "None", params: []},
				{name: "Some", params: [I32]},
				{name: "Node", params: [Obj("Node")]}
			]
		});
		program.staticFields = [
			{name: "nodes", type: Array(Obj("Node"))},
			{name: "iterator", type: Iterator(Obj("Node"))},
			{name: "callback", type: Function([Obj("Node")], Enum("Choice"))},
			{name: "dynamic", type: Dyn},
			{name: "type", type: TypeRef},
			{name: "bytes", type: Bytes},
			{name: "managedBytes", type: ManagedBytes},
			{name: "abstract", type: Abstract("Handle")},
			{name: "virtual", type: Virtual("Readable")}
		];
		var mainBuilder = new IrBuilder();
		mainBuilder.returnValue(mainBuilder.constInt(42));
		program.functions.push(new IrFunction("main", mainBuilder.arguments, I32, mainBuilder.blocks));

		var plan = new WasmGcTypePlan(program),
			baseIndex = plan.objectType("Base"),
			nodeIndex = plan.objectType("Node");
		var repeatedPlan = new WasmGcTypePlan(program);
		if (repeatedPlan.objectType("Node") != nodeIndex
			|| repeatedPlan.enumConstructorType("Choice", 2) != plan.enumConstructorType("Choice", 2)
			|| repeatedPlan.arrayStorageType(Obj("Node")) != plan.arrayStorageType(Obj("Node"))
			|| repeatedPlan.functionTypeIndex([], I32) != plan.functionTypeIndex([], I32))
			throw "Wasm GC type indices must be stable for identical IR programs";
		if (baseIndex >= nodeIndex
			|| plan.objectFieldIndex("Node", "id") != 0
			|| plan.objectFieldIndex("Node", "parent") != 1
			|| plan.objectFieldIndex("Node", "children") != 2)
			throw "Wasm GC object types must reserve parent-first field indices";
		var enumIndex = plan.enumType("Choice"),
			nodeConstructorIndex = plan.enumConstructorType("Choice", 2);
		if (plan.enumFieldIndex("Choice", 2, 0) != 1)
			throw "Wasm GC enum payload fields must follow the shared tag";
		var nodesArrayIndex = plan.arrayType(Obj("Node")),
			nodeStorageIndex = plan.arrayStorageType(Obj("Node")),
			iteratorIndex = plan.iteratorType(Obj("Node"));
		var dynamicIsAnyRef = switch plan.valueType(Dyn) {
			case Ref(ref): ref.nullable && isAnyHeapType(ref.heap);
			default: false;
		};
		var managedBytesIsByteArray = switch plan.valueType(ManagedBytes) {
			case Ref(ref): ref.nullable && isTypeHeap(ref.heap, plan.byteArrayTypeIndex);
			default: false;
		};
		if (!dynamicIsAnyRef
			|| plan.valueType(TypeRef) != I32
			|| !managedBytesIsByteArray
			|| plan.boxedPrimitiveType(Bool) == plan.boxedPrimitiveType(I32))
			throw "Wasm GC value and box types must preserve the planned representations";

		var module = new WasmModule("WasmGcTypePlanMain");
		plan.addTo(module);
		var nodeFields = switch module.typeAt(nodeIndex).composite {
			case Struct(fields): fields;
			default: throw "A Haxe object must plan as a GC struct";
		};
		var recursiveParent = switch nodeFields[1].type {
			case Value(Ref(ref)): isTypeHeap(ref.heap, nodeIndex);
			default: false;
		};
		var objectSubtype = module.typeAt(nodeIndex).supertypes.length == 1 && module.typeAt(nodeIndex).supertypes[0] == baseIndex;
		var nodeArrayType = switch module.typeAt(nodesArrayIndex).composite {
			case Struct(fields): fields;
			default: throw "A Haxe array must plan as a wrapper struct";
		};
		var storageType = switch module.typeAt(nodeStorageIndex).composite {
			case Array(field): field;
			default: throw "A Haxe array must have a separate GC storage array";
		};
		var iteratorFields = switch module.typeAt(iteratorIndex).composite {
			case Struct(fields): fields;
			default: throw "A Haxe iterator must plan as a GC struct";
		};
		var enumSubtype = module.typeAt(nodeConstructorIndex),
			nodeElementType = switch storageType.type {
				case Value(Ref(ref)): isTypeHeap(ref.heap, nodeIndex);
				default: false;
			},
			arrayDataType = switch nodeArrayType[1].type {
				case Value(Ref(ref)): !ref.nullable && isTypeHeap(ref.heap, nodeStorageIndex);
				default: false;
			},
			iteratorArrayType = switch iteratorFields[0].type {
				case Value(Ref(ref)): ref.nullable && isTypeHeap(ref.heap, nodesArrayIndex);
				default: false;
			};
		var callbackUsesClosure = switch plan.valueType(Function([Obj("Node")], Enum("Choice"))) {
			case Ref(ref): ref.nullable && isTypeHeap(ref.heap, plan.closureTypeIndex);
			default: false;
		};
		if (!recursiveParent || !objectSubtype || !nodeElementType || !arrayDataType || !iteratorArrayType || !callbackUsesClosure
			|| enumSubtype.supertypes[0] != enumIndex)
			throw "Wasm GC type plan lost a recursive reference, wrapper, iterator, or enum subtype";

		var signature = plan.wasmFunctionType([], I32),
			plannedSignatureIndex = plan.functionTypeIndex([], I32);
		if (module.typeIndex(signature) != plannedSignatureIndex)
			throw "Function lowering must reuse a signature reserved by the Wasm GC type plan";
		var callbackSignature = plan.wasmFunctionType([Obj("Node")], Enum("Choice"));
		if (module.typeIndex(callbackSignature) != plan.functionTypeIndex([Obj("Node")], Enum("Choice")))
			throw "Closure call signatures must be reserved before function lowering";
		module.addFunction(new WasmFunction("main", signature, [], [I32Const(42), Return]));
		module.exports.push({name: "main", functionIndex: 0});
		validateGcTypePlanRejectsInvalidPrograms();
		return WasmEncoder.encode(module);
	}

	static function validateGcTypePlanRejectsInvalidPrograms():Void {
		var cycle = new IrProgram("main");
		cycle.objects = [
			{
				name: "First",
				isValue: false,
				base: "Second",
				interfaces: [],
				fields: [],
				methods: []
			},
			{
				name: "Second",
				isValue: false,
				base: "First",
				interfaces: [],
				fields: [],
				methods: []
			}
		];
		assertGcTypePlanRejected(cycle, "The Wasm GC type planner accepted cyclic class inheritance");

		var missing = new IrProgram("main");
		missing.staticFields.push({name: "missing", type: Obj("Missing")});
		assertGcTypePlanRejected(missing, "The Wasm GC type planner accepted an undeclared object reference");
	}

	static function assertGcTypePlanRejected(program:IrProgram, message:String):Void {
		var rejected = false;
		try {
			new WasmGcTypePlan(program);
		} catch (_:Dynamic) {
			rejected = true;
		}
		if (!rejected)
			throw message;
	}

	static function isAnyHeapType(heap:WasmHeapType):Bool
		return switch heap {
			case Any: true;
			default: false;
		};

	static function isTypeHeap(heap:WasmHeapType, index:Int):Bool
		return switch heap {
			case Type(actual): actual == index;
			default: false;
		};

	static function compileGcTypeModel():haxe.io.Bytes {
		var module = new WasmModule("WasmGcModelMain"),
			nodeType:WasmSubtype = {
				finalType: false,
				supertypes: [],
				composite: Struct([
					{type: Value(I32), mutable: true},
					{type: Value(Ref({nullable: true, heap: Type(0)})), mutable: true},
					{type: I8, mutable: true},
					{type: I16, mutable: true}
				])
			};
		var childType:WasmSubtype = {
			finalType: true,
			supertypes: [0],
			composite: Struct([
				{type: Value(I32), mutable: true},
				{type: Value(Ref({nullable: true, heap: Type(0)})), mutable: true},
				{type: I8, mutable: true},
				{type: I16, mutable: true},
				{type: Value(I32), mutable: true}
			])
		};
		if (module.addRecGroup([nodeType, childType]) != 0)
			throw "The first recursive Wasm GC type must receive index zero";
		var intArrayType = module.addType({
			finalType: true,
			supertypes: [],
			composite: Array({type: Value(I32), mutable: true})
		});
		if (intArrayType != 2)
			throw "Type indices after a recursive group must count its contained types";
		var byteArrayType = module.addType({
			finalType: true,
			supertypes: [],
			composite: Array({type: I8, mutable: true})
		});
		var signature:WasmFunctionType = {parameters: [], results: [I32]},
			body:Array<WasmInstruction> = [
				StructNewDefault(0),
				LocalSet(0),
				I32Const(0),
				RefNull(Type(0)),
				I32Const(0),
				I32Const(0),
				I32Const(0),
				StructNew(1),
				LocalSet(1),
				LocalGet(0),
				I32Const(39),
				StructSet(0, 0),
				LocalGet(0),
				LocalGet(1),
				StructSet(0, 1),
				LocalGet(0),
				I32Const(255),
				StructSet(0, 2),
				LocalGet(0),
				I32Const(65535),
				StructSet(0, 3),
				LocalGet(0),
				StructGetSigned(0, 2),
				Drop,
				LocalGet(0),
				StructGetUnsigned(0, 3),
				Drop,
				LocalGet(0),
				StructGet(0, 1),
				RefTest({
					nullable: true,
					heap: Type(0)
				}),
				LocalGet(0),
				StructGet(0, 1),
				RefCast({nullable: false, heap: Type(0)}),
				Drop,
				LocalGet(0),
				StructGet(0, 1),
				LocalGet(1),
				RefEq,
				LocalGet(1),
				StructGet(0, 1),
				RefIsNull,
				LocalGet(0),
				StructGet(0, 0),
				I32Add,
				I32Add,
				I32Add,
				I32Const(42),
				I32Eq,
				I32Const(7),
				I32Const(2),
				ArrayNew(intArrayType),
				LocalSet(2),
				LocalGet(2),
				ArrayLen,
				I32Const(2),
				I32Eq,
				I32And,
				I32Const(2),
				ArrayNewDefault(intArrayType),
				LocalSet(3),
				LocalGet(2),
				I32Const(1),
				I32Const(42),
				ArraySet(intArrayType),
				LocalGet(3),
				I32Const(0),
				LocalGet(2),
				I32Const(1),
				I32Const(1),
				ArrayCopy(intArrayType, intArrayType),
				LocalGet(3),
				I32Const(0),
				ArrayGet(intArrayType),
				I32Const(42),
				I32Eq,
				I32And,
				I32Const(255),
				I32Const(1),
				ArrayNew(byteArrayType),
				LocalSet(4),
				LocalGet(4),
				I32Const(0),
				I32Const(255),
				ArraySet(byteArrayType),
				LocalGet(4),
				I32Const(0),
				ArrayGetSigned(byteArrayType),
				Drop,
				LocalGet(4),
				I32Const(0),
				ArrayGetUnsigned(byteArrayType),
				Drop,
				If(I32),
				I32Const(42),
				Else,
				I32Const(0),
				End
			];
		module.addFunction(new WasmFunction("main", signature, [
			{type: Ref({nullable: false, heap: Type(0)})},
			{type: Ref({nullable: false, heap: Type(1)})},
			{type: Ref({nullable: false, heap: Type(intArrayType)})},
			{type: Ref({nullable: false, heap: Type(intArrayType)})},
			{type: Ref({nullable: false, heap: Type(byteArrayType)})}
		], body));
		module.exports.push({name: "main", functionIndex: 0});
		return WasmEncoder.encode(module);
	}

	static function validateGcModelRejectsInvalidModules():Void {
		var invalidReference = new WasmModule();
		invalidReference.addType({
			finalType: true,
			supertypes: [],
			composite: Array({type: Value(Ref({nullable: true, heap: Type(1)})), mutable: true})
		});
		assertGcModuleRejected(invalidReference, "The Wasm validator accepted a forward reference outside its recursive group");

		var immutableField = new WasmModule(),
			voidSignature:WasmFunctionType = {parameters: [], results: []};
		immutableField.addType({
			finalType: true,
			supertypes: [],
			composite: Struct([{type: Value(I32), mutable: false}])
		});
		immutableField.addFunction(new WasmFunction("writeImmutable", voidSignature, [], [StructNewDefault(0), I32Const(7), StructSet(0, 0)]));
		assertGcModuleRejected(immutableField, "The Wasm validator accepted a write to an immutable GC field");
	}

	static function assertGcModuleRejected(module:WasmModule, message:String):Void {
		var rejected = false;
		try {
			WasmValidator.validate(module);
		} catch (_:Dynamic) {
			rejected = true;
		}
		if (!rejected)
			throw message;
	}

	static function objectProgram():haxe.io.Bytes {
		var builder = new IrBuilder(),
			object = builder.newObject("Box"),
			value = builder.constInt(42);
		builder.fieldSet(object, "value", value);
		builder.returnValue(builder.fieldGet(object, "value", I32));
		var program = new IrProgram("main");
		program.objects.push({
			name: "Box",
			isValue: false,
			base: null,
			interfaces: [],
			fields: [{name: "value", type: I32}],
			methods: []
		});
		program.functions.push(new IrFunction("main", [], I32, builder.blocks));
		return new WasmBackend().compile(program, {target: Wasm32, debugNames: true}).bytes;
	}

	static function int64StringProgram():IrProgram {
		var program = Frontend.compile("function main():Int return 42;"),
			block = new IrBlock(0),
			high = new IrValue(0, "high", I32),
			low = new IrValue(1, "low", I32),
			wide = new IrValue(2, "wide", I64),
			boxed = new IrValue(3, "boxed", Dyn),
			text = new IrValue(4, "text", Bytes),
			provenance = SourceProvenance.generated("wasm-std-string-test");
		program.natives = program.natives.concat([
			{name: "haxe.Int64.make", library: "haxeon_runtime", symbol: "__int64_make", arguments: [I32, I32], result: I64},
			{name: "__std_string", library: "haxeon_runtime", symbol: "__std_string", arguments: [Dyn], result: Bytes}
		]);
		block.instructions.push(new Located(Call(wide, "haxe.Int64.make", [high, low]), provenance));
		block.instructions.push(new Located(ToDyn(boxed, wide), provenance));
		block.instructions.push(new Located(Call(text, "__std_string", [boxed]), provenance));
		block.terminator = new Located(Return(text), provenance);
		program.functions.push(new IrFunction("stringifyInt64", [high, low], Bytes, [block]));
		return program;
	}

	static function floatStringProgram():IrProgram {
		var program = Frontend.compile("function main():Int return 42;"),
			block = new IrBlock(0),
			value = new IrValue(0, "value", F64),
			boxed = new IrValue(1, "boxed", Dyn),
			text = new IrValue(2, "text", Bytes),
			provenance = SourceProvenance.generated("wasm-std-string-test");
		program.natives.push({
			name: "__std_string",
			library: "haxeon_runtime",
			symbol: "__std_string",
			arguments: [Dyn],
			result: Bytes
		});
		block.instructions.push(new Located(ToDyn(boxed, value), provenance));
		block.instructions.push(new Located(Call(text, "__std_string", [boxed]), provenance));
		block.terminator = new Located(Return(text), provenance);
		program.functions.push(new IrFunction("stringifyFloat", [value], Bytes, [block]));
		return program;
	}

	static function compile(source:String):haxe.io.Bytes {
		var result = new WasmBackend().compile(Frontend.compile(source), {target: Wasm32, debugNames: true});
		if (result.bytes.length < 8 || result.bytes.get(0) != 0 || result.bytes.get(1) != 97 || result.bytes.get(2) != 115 || result.bytes.get(3) != 109)
			throw "Wasm module is missing its binary header";
		return result.bytes;
	}

	static function containsBytes(bytes:haxe.io.Bytes, value:String):Bool {
		for (start in 0...bytes.length - value.length + 1) {
			var found = true;
			for (offset in 0...value.length)
				if (bytes.get(start + offset) != value.charCodeAt(offset)) {
					found = false;
					break;
				}
			if (found)
				return true;
		}
		return false;
	}
}
