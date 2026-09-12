import compiler.Frontend;
import compiler.backend.Backend.BackendTarget;
import compiler.backend.hl.HlBackend;
import compiler.backend.wasm.WasmBackend;
import compiler.backend.wasm.WasmTarget;
import compiler.backend.wasm.WasmTarget.WasmReferenceModel;
import compiler.backend.wasm.WasmLayout;
import compiler.backend.wasm.WasmRuntimeAbi;
import compiler.backend.wasm.WasmGcRoots;
import compiler.backend.wasm.WasmStructurer;
import compiler.backend.wasm.WasmPatch;
import compiler.abi.PatchPlanner.PatchDecision;
import compiler.ir.IrInterpreter;
import compiler.ir.codec.CanonicalIrCodec;
import compiler.ir.IrBuilder;
import compiler.ir.IrFunction;
import compiler.ir.Ir.IrInstruction;
import compiler.ir.Ir.IrProgram;
import compiler.ir.Ir.IrType;
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
		var referenceProgram = Frontend.compile("function sum(value:Int):Int { var result = 0; while (value > 0) { result = result + value; value = value - 1; } return result; } function main():Int return sum(3);");
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
		if (new IrInterpreter(Frontend.compile("function fail():Void { throw \"boom\"; } function main():Int { var value = 0; try { fail(); } catch (error:Dynamic) { value = 42; } return value; }"))
			.run("main") != 42)
			throw "The SSA interpreter must execute exception edges";
		if (new IrInterpreter(Frontend.compile("class Base { public var value:Int; public function new() { value = 42; } } class Child extends Base { public function new() { super(); } } function main():Int { var child = new Child(); return child.value; }"))
			.run("main") != 42)
			throw "The SSA interpreter must preserve inherited object fields";
		var first = compile("function main():Int return 40 + 2;");
		var branch = compile("function main():Int { var value:Int; if (true) value = 40; else value = 2; return value + 2; }");
		var loop = compile("function sum(value:Int):Int { var result = 0; while (value > 0) { result = result + value; value = value - 1; } return result; } function main():Int return sum(3);");
		var array = compile("function main():Int { var values = new Array<Int>(1); values[0] = 42; return values[0]; }");
		var floatArray = compile("function main():Int { var values = new Array<Float>(1); values[0] = 40.5; return values[0] == 40.5 ? 42 : 0; }");
		var arrayOps = compile("function main():Int { var first = [40]; var second = [2]; var combined = first.concat(second); return combined[0] + combined[1]; }");
		var arrayMutation = compile("function main():Int { var values = [40]; values.push(2); return values.pop() + values[0]; }");
		var string = compile("function main():Int return \"haxeon\".length;");
		var stringOps = compile("function main():Int return (\"ha\" + \"xeon\" == \"haxeon\") ? 42 : 0;");
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
		Sys.println("PASS: Wasm scalar backend");
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

	static function compile(source:String):haxe.io.Bytes {
		var result = new WasmBackend().compile(Frontend.compile(source), {target: Wasm32, debugNames: true});
		if (result.bytes.length < 8 || result.bytes.get(0) != 0 || result.bytes.get(1) != 97 || result.bytes.get(2) != 115 || result.bytes.get(3) != 109)
			throw "Wasm module is missing its binary header";
		return result.bytes;
	}
}
