import compiler.backend.Backend.BackendTarget;
import compiler.backend.wasm.WasmBackend;
import compiler.ir.Ir;
import compiler.ir.IrBuilder;
import compiler.ir.IrFunction;
import compiler.ir.IrInterpreter;
import compiler.ir.IrVerifier;
import compiler.ir.SourceProvenance;
import compiler.ir.SourceProvenance.Located;
import sys.io.File;

/** The Wasm iterator header retains its semantic element type without another allocation. */
class IteratorTypeDescriptorMain {
	static function main():Void {
		var b = new IrBuilder(), ints = b.call("__array_alloc_i32", [b.constInt(1)], Array(I32)),
			strings = b.call("__array_alloc_bytes", [b.constInt(1)], Array(Bytes)),
			nested = b.call("__array_alloc_typed_ref", [b.constInt(1), b.typeValue(Array(I32))], Array(Array(I32))),
			intIterator = new IrValue(1000000, "intIterator", Iterator(I32)),
			stringIterator = new IrValue(1000001, "stringIterator", Iterator(Bytes)),
			nestedIterator = new IrValue(1000004, "nestedIterator", Iterator(Array(I32))),
			intValue = b.constInt(17), stringValue = b.constString("kept"), provenance = SourceProvenance.generated("iterator-type-test");
		b.currentBlock().instructions.push(new Located(ArraySet(ints, b.constInt(0), intValue), provenance));
		b.currentBlock().instructions.push(new Located(ArraySet(strings, b.constInt(0), stringValue), provenance));
		b.currentBlock().instructions.push(new Located(IteratorNew(intIterator, ints), provenance));
		b.currentBlock().instructions.push(new Located(IteratorNew(stringIterator, strings), provenance));
		b.currentBlock().instructions.push(new Located(IteratorNew(nestedIterator, nested), provenance));
		var dynamicInt = b.toDyn(intIterator), dynamicString = b.toDyn(stringIterator), dynamicNested = b.toDyn(nestedIterator),
			intType = b.typeValue(Iterator(I32)), stringType = b.typeValue(Iterator(Bytes)),
			intMatches = b.call("__std_is_of_type", [dynamicInt, intType], Bool),
			intMismatch = b.call("__std_is_of_type", [dynamicInt, stringType], Bool),
			stringMatches = b.call("__std_is_of_type", [dynamicString, stringType], Bool),
			stringMismatch = b.call("__std_is_of_type", [dynamicString, intType], Bool),
			nestedMatches = b.call("__std_is_of_type", [dynamicNested, b.typeValue(Iterator(Array(I32)))], Bool),
			nestedMismatch = b.call("__std_is_of_type", [dynamicNested, b.typeValue(Iterator(Array(Bytes)))], Bool),
			checkIntMismatch = b.createBlock(), checkString = b.createBlock(), checkStringMismatch = b.createBlock(),
			checkNested = b.createBlock(), checkNestedMismatch = b.createBlock(),
			readValues = b.createBlock(), checkStringValue = b.createBlock(), pass = b.createBlock(), fail = b.createBlock();
		b.branch(intMatches, checkIntMismatch, fail);
		b.select(checkIntMismatch); b.branch(intMismatch, fail, checkString);
		b.select(checkString); b.branch(stringMatches, checkStringMismatch, fail);
		b.select(checkStringMismatch); b.branch(stringMismatch, fail, checkNested);
		b.select(checkNested); b.branch(nestedMatches, checkNestedMismatch, fail);
		b.select(checkNestedMismatch); b.branch(nestedMismatch, fail, readValues);
		b.select(readValues);
		var nextInt = new IrValue(1000002, "nextInt", I32), nextString = new IrValue(1000003, "nextString", Bytes);
		b.currentBlock().instructions.push(new Located(IteratorNext(nextInt, intIterator), provenance));
		b.currentBlock().instructions.push(new Located(IteratorNext(nextString, stringIterator), provenance));
		b.branch(b.equal(nextInt, intValue), checkStringValue, fail);
		b.select(checkStringValue); b.branch(b.equal(nextString, stringValue), pass, fail);
		b.select(pass); b.returnValue(b.constInt(42));
		b.select(fail); b.returnValue(b.constInt(1));
		var program = new IrProgram("main");
		program.natives = [
			{name: "__array_alloc_i32", library: "haxeon_runtime", symbol: "__array_alloc_i32", arguments: [I32], result: Array(I32)},
			{name: "__array_alloc_bytes", library: "haxeon_runtime", symbol: "__array_alloc_bytes", arguments: [I32], result: Array(Bytes)},
			{name: "__array_alloc_ref", library: "haxeon_runtime", symbol: "__array_alloc_ref", arguments: [I32], result: Array(Dyn)},
			{name: "__array_alloc_typed_ref", library: "haxeon_runtime", symbol: "__array_alloc_typed_ref", arguments: [I32, TypeRef], result: Array(Dyn)},
			{name: "__std_is_of_type", library: "haxeon_runtime", symbol: "__std_is_of_type", arguments: [Dyn, TypeRef], result: Bool}
		];
		program.functions = [new IrFunction("main", b.arguments, I32, b.blocks)];
		program.objects.push({name: "Holder", isValue: false, base: null, interfaces: [],
			fields: [{name: "value", type: Iterator(I32)}], methods: []});
		var write = new IrBuilder(), holder = write.newObject("Holder"), receiver = write.toDyn(holder),
			goodArray = write.call("__array_alloc_i32", [write.constInt(1)], Array(I32)),
			badArray = write.call("__array_alloc_bytes", [write.constInt(1)], Array(Bytes)),
			good = new IrValue(1000010, "good", Iterator(I32)), bad = new IrValue(1000011, "bad", Iterator(Bytes));
		write.currentBlock().instructions.push(new Located(IteratorNew(good, goodArray), provenance));
		write.currentBlock().instructions.push(new Located(IteratorNew(bad, badArray), provenance));
		write.call("$generic-erased:Holder:set:value", [receiver, write.toDyn(good)], Void);
		var wrong = write.toDyn(bad), body = write.createBlock(), caught = write.createBlock(), after = write.createBlock(),
			unchanged = write.createBlock(), changed = write.createBlock();
		write.currentBlock().instructions.push(new Located(BeginTry(caught.id, after.id, false), provenance));
		write.jump(body);
		write.select(body); write.call("$generic-erased:Holder:set:value", [receiver, wrong], Void);
		body.instructions.push(new Located(EndTry(caught.id, false), provenance));
		write.jump(after);
		write.select(caught); caught.instructions.push(new Located(Catch(new IrValue(1000012, "caught", Dyn)), provenance));
		write.branch(write.equal(write.fieldGet(holder, "value", Iterator(I32)), good), unchanged, changed);
		write.select(unchanged); write.returnValue(write.constInt(42));
		write.select(changed); write.returnValue(write.constInt(2));
		write.select(after); write.returnValue(write.constInt(1));
		program.functions.push(new IrFunction("erasedWrite", [], I32, write.blocks));
		compiler.ir.GenericOwnerErasure.generate(compiler.ir.ProgramFacts.empty(), program.functions, program.objects);
		IrVerifier.verify(program);
		if (new IrInterpreter(program).run() != 42) throw "interpreter lost an iterator element type";
		if (new IrInterpreter(program).run("erasedWrite") != 42) throw "interpreter accepted an invalid erased iterator write";
		for (target in [Wasm32, WasmGc]) {
			var wasm = new WasmBackend().compile(program, {target: target, debugNames: true, wasmGcStress: target == Wasm32,
				exports: ["erasedWrite"]}).bytes,
				directory = Sys.getEnv("TMPDIR");
			if (directory == null || directory == "") directory = Sys.getCwd() + "/out/test-tools";
			if (!sys.FileSystem.exists(directory)) sys.FileSystem.createDirectory(directory);
			var path = '$directory/haxeon-iterator-type-${Std.random(0x7fffffff)}.wasm';
			File.saveBytes(path, wasm);
			var script = 'const fs=require("fs"), i=new WebAssembly.Instance(new WebAssembly.Module(fs.readFileSync(process.argv[1]))); '
				+ 'const result=i.exports.main(), write=i.exports.erasedWrite(); '
				+ 'if(result!==42 || write!==42) { console.error("result="+result+", write="+write); process.exit(1); }';
			var process = new sys.io.Process("node", ["-e", script, path]), error = process.stderr.readAll().toString(), status = process.exitCode();
			process.close(); sys.FileSystem.deleteFile(path);
			if (status != 0) throw '$target iterator element descriptor failed: $error';
		}
		checkValueArrayIterators();
		checkAllocations();
		Sys.println("PASS: iterator descriptors distinguish element types and retain their arrays");
	}

	static function checkValueArrayIterators():Void {
		var source = 'struct LaneA { public var value:Int; } struct LaneB { public var value:Int; } '
			+ 'class LaneCensus { public static function first():Dynamic { var a:Array<LaneA>=[]; var it=a.iterator(); return it; } '
			+ 'public static function second():Dynamic { var b:Array<LaneB>=[]; var it=b.iterator(); return it; } } '
			+ 'function main():Int return 42;';
		for (inlineEnabled in [false, true]) for (target in [Wasm32, WasmGc]) {
			var program = compiler.Frontend.compile(source), check = new IrBuilder(),
				first = check.call("LaneCensus.first", [], Dyn), second = check.call("LaneCensus.second", [], Dyn),
				a = check.typeValue(Iterator(Obj("LaneA"))), b = check.typeValue(Iterator(Obj("LaneB"))),
				firstMatches = check.call("__std_is_of_type", [first, a], Bool),
				firstMismatch = check.call("__std_is_of_type", [first, b], Bool),
				secondMatches = check.call("__std_is_of_type", [second, b], Bool),
				secondMismatch = check.call("__std_is_of_type", [second, a], Bool),
				checkFirstMismatch = check.createBlock(), checkSecond = check.createBlock(), checkSecondMismatch = check.createBlock(),
				pass = check.createBlock(), fail = check.createBlock();
			check.branch(firstMatches, checkFirstMismatch, fail);
			check.select(checkFirstMismatch); check.branch(firstMismatch, fail, checkSecond);
			check.select(checkSecond); check.branch(secondMatches, checkSecondMismatch, fail);
			check.select(checkSecondMismatch); check.branch(secondMismatch, fail, pass);
			check.select(pass); check.returnValue(check.constInt(42));
			check.select(fail); check.returnValue(check.constInt(1));
			program.functions.push(new IrFunction("checkLanes", [], I32, check.blocks));
			if (![for (native in program.natives) native.name].contains("__std_is_of_type"))
				program.natives.push({name: "__std_is_of_type", library: "haxeon_runtime", symbol: "__std_is_of_type", arguments: [Dyn, TypeRef], result: Bool});
			compiler.ir.IrValueArrayProgramRewrite.rewriteAll(program, 32, target == Wasm32 ? Wasm32 : WasmGc);
			compiler.ir.IrValueConstructors.rewrite(program);
			compiler.ir.IrValuePhiScalarization.rewrite(program);
			compiler.ir.IrScalarArguments.rewrite(program, true);
			compiler.ir.IrValuePhiScalarization.rewrite(program);
			var objects = compiler.ir.IrObjectTable.of([for (object in program.objects) object.name => object]);
			program.functions = [for (fn in program.functions) compiler.ir.IrScalarReplacement.rewrite(fn, objects, false, true)];
			compiler.ir.IrNullableScalarFlow.rewrite(program);
			compiler.ir.IrInliner.run(program, new compiler.ir.IrInliner.IrInlineCache(), compiler.ir.TargetProfile.wasm, inlineEnabled);
			var wasm = new WasmBackend().compile(program, {target: target, debugNames: true, wasmGcStress: target == Wasm32,
				exports: ["checkLanes"]}).bytes, directory = Sys.getEnv("TMPDIR");
			if (directory == null || directory == "") directory = Sys.getCwd() + "/out/test-tools";
			if (!sys.FileSystem.exists(directory)) sys.FileSystem.createDirectory(directory);
			var path = '$directory/haxeon-value-iterator-type-${Std.random(0x7fffffff)}.wasm';
			File.saveBytes(path, wasm);
			var script = 'const fs=require("fs"), i=new WebAssembly.Instance(new WebAssembly.Module(fs.readFileSync(process.argv[1]))); '
				+ 'const result=i.exports.checkLanes(); if(result!==42) throw Error("result="+result);';
			var process = new sys.io.Process("node", ["-e", script, path]), error = process.stderr.readAll().toString(), status = process.exitCode();
			process.close(); sys.FileSystem.deleteFile(path);
			if (status != 0) throw '$target value-array iterator descriptor (inline=$inlineEnabled) failed: $error';
		}
	}

	static function checkAllocations():Void {
		var source = File.getContent("tests/programs/wasm-bytes-runtime-kinds.hx");
		for (inlineEnabled in [false, true]) for (target in [Wasm32, WasmGc]) {
			var runtime = new compiler.Compiler(null, compiler.runtime.CompilerIntrinsics.configuration());
			runtime.addSourceRoot("stdlib");
			runtime.update("Main.hx", source);
			var program = runtime.compile("Main").ir;
			compiler.ir.IrInliner.run(program, new compiler.ir.IrInliner.IrInlineCache(), compiler.ir.TargetProfile.wasm, inlineEnabled);
			var wasm = new WasmBackend().compile(program, {target: target, debugNames: true,
				wasmMemoryStats: target == Wasm32, wasmGcAllocationCount: target == WasmGc,
				exports: ["BytesIteratorCensus.prepare", "BytesIteratorCensus.iterate", "BytesIteratorCensus.allocateBytes"]}).bytes,
				directory = Sys.getEnv("TMPDIR");
			if (directory == null || directory == "") directory = Sys.getCwd() + "/out/test-tools";
			if (!sys.FileSystem.exists(directory)) sys.FileSystem.createDirectory(directory);
			var path = '$directory/haxeon-iterator-census-${Std.random(0x7fffffff)}.wasm';
			File.saveBytes(path, wasm);
			var script = 'const fs=require("fs"), i=new WebAssembly.Instance(new WebAssembly.Module(fs.readFileSync(process.argv[1]))); '
				+ 'i.exports["BytesIteratorCensus.prepare"](); const counter=i.exports.__allocation_count||i.exports["haxeon.memory.allocation_count"]; '
				+ 'for(const [name,factor,objects] of [["iterate",7,1],["allocateBytes",4,' + (target == Wasm32 ? '1' : '2') + ']]) '
				+ 'for(const n of [8,1024]) { const before=counter(), result=i.exports["BytesIteratorCensus."+name](n), count=counter()-before; '
				+ 'if(result!==n*factor || count>n*objects) throw Error(name+" n="+n+", result="+result+", allocations="+count); }';
			var process = new sys.io.Process("node", ["-e", script, path]), error = process.stderr.readAll().toString(), status = process.exitCode();
			process.close(); sys.FileSystem.deleteFile(path);
			if (status != 0) throw '$target bytes and iterator allocation census (inline=$inlineEnabled) failed: $error';
		}
	}
}
