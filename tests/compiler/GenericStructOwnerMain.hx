import compiler.Frontend;
import compiler.backend.Backend.BackendTarget;
import compiler.ir.Ir;
import sys.io.File;

/** Generic class fields and methods use the concrete value representation, including inherited owners. */
class GenericStructOwnerMain {
	static function main():Void {
		var referenceRuntime = new compiler.Compiler(null, compiler.runtime.CompilerIntrinsics.configuration());
		referenceRuntime.addStandardLibrarySourceRoot("stdlib");
		referenceRuntime.update("Main.hx", File.getContent("tests/programs/generic-erased-reference-checks.hx"));
		if (new compiler.ir.IrInterpreter(referenceRuntime.compile("Main").ir).run("main") != 42)
			throw "erased reference writes did not preserve checked value semantics in the interpreter";
		var arraySource = File.getContent("tests/programs/generic-erased-array-function-checks.hx");
		arraySource = StringTools.replace(StringTools.replace(StringTools.replace(arraySource, "#if !wasm", ""), "#end", ""), "hl.Gc.totalAllocated()", "0");
		var checkedArrays = Frontend.compile(arraySource);
		if (new compiler.ir.IrInterpreter(checkedArrays).run("main") != 42)
			throw "erased array and function writes did not preserve checked value semantics in the interpreter";
		var pointerSource = File.getContent("tests/programs/generic-erased-raw-pointer.hx"),
			pointerNative = pointerSource.indexOf("#if !wasm"), pointerNativeEnd = pointerSource.indexOf("#end", pointerNative);
		if (pointerNative < 0 || pointerNativeEnd < 0) throw "missing raw pointer native fixture";
		pointerSource = pointerSource.substring(0, pointerNative) + pointerSource.substring(pointerNativeEnd + 4);
		pointerSource = pointerSource.substring(0, pointerSource.indexOf("function main():Int"))
			+ "function main():Int return PointerBoundaryCensus.prepare(null);";
		var pointerRuntime = new compiler.Compiler(null, compiler.runtime.CompilerIntrinsics.configuration());
		pointerRuntime.addStandardLibrarySourceRoot("stdlib");
		pointerRuntime.update("Main.hx", pointerSource);
		if (new compiler.ir.IrInterpreter(pointerRuntime.compile("Main").ir).run("main") != 42)
			throw "erased pointer writes and checked casts failed in the interpreter";
		var callbackSource = File.getContent("tests/programs/generic-erased-native-callback.hx");
		callbackSource = callbackSource.substring(0, callbackSource.indexOf("function main():Int"))
			+ "function main():Int return checkCallback(null);";
		var callbackRuntime = new compiler.Compiler(null, compiler.runtime.CompilerIntrinsics.configuration());
		callbackRuntime.addStandardLibrarySourceRoot("stdlib");
		callbackRuntime.update("Main.hx", callbackSource);
		if (new compiler.ir.IrInterpreter(callbackRuntime.compile("Main").ir).run("main") != 42)
			throw "erased callback writes and null handling failed in the interpreter";
		checkTypeHandleDynamic();
		checkCallbackAllocations();
		var interfaceSource = File.getContent("tests/programs/generic-interface-value-carriers.hx");
		interfaceSource = StringTools.replace(StringTools.replace(StringTools.replace(interfaceSource, "#if !wasm", ""), "#end", ""), "hl.Gc.totalAllocated()", "0");
		var interfaceRuntime = new compiler.Compiler(null, compiler.runtime.CompilerIntrinsics.configuration());
		interfaceRuntime.addStandardLibrarySourceRoot("stdlib");
		interfaceRuntime.update("Main.hx", interfaceSource);
		if (new compiler.ir.IrInterpreter(interfaceRuntime.compile("Main").ir).run("main") != 42)
			throw "typed generic interface calls lost their value carriers in the interpreter";
		var checkedSignatures = Frontend.compile(File.getContent("tests/programs/generic-erased-function-reference-shapes.hx"));
		var collisionFirst:IrType = Function([Obj("Cba95abb6358835f5")], Bytes),
			collisionSecond:IrType = Function([Obj("Cefe1ade6cf91fbfe")], Bytes);
		if (compiler.ir.IrTypeIdentity.id(collisionFirst) != compiler.ir.IrTypeIdentity.id(collisionSecond))
			throw "closure signature collision fixture no longer collides";
		if (new compiler.ir.IrInterpreter(checkedSignatures).run("main") != 42)
			throw "the interpreter did not distinguish reference-shaped closure signatures";
		var program = Frontend.compile(File.getContent("tests/programs/generic-struct-class.hx"));
		var payloadOwner:Null<String> = null, otherOwner:Null<String> = null;
		for (object in program.objects) for (field in object.fields)
			if (field.name == "value" && StringTools.startsWith(object.name, '$' + 'generic:$' + 'owner:Box')) switch field.type {
			case Obj("Payload"): payloadOwner = object.name;
			case Obj("OtherPayload"): otherOwner = object.name;
			default:
		}
		if (payloadOwner == null || otherOwner == null || payloadOwner == otherOwner)
			throw 'generic value owners are missing or share storage: $payloadOwner, $otherOwner';
		var derived = false, get = false, replace = false;
		for (object in program.objects) {
			if (object.base == payloadOwner) derived = true;
			if (object.name == payloadOwner) for (method in object.methods) for (fn in program.functions)
				if (fn.name == method.functionName) {
					if (method.name == "get") get = Type.enumEq(fn.result, Obj("Payload"));
					if (method.name == "replace") replace = fn.arguments.length == 2 && Type.enumEq(fn.arguments[1].type, Obj("Payload"));
				}
		}
		if (!derived || !get || !replace) throw 'specialized inheritance or method ABI is missing: $derived, $get, $replace';
		var interpreted = new compiler.ir.IrInterpreter(program).run("main");
		if (interpreted != 42)
			throw 'generic value owner or Dynamic view lost value semantics: $interpreted';
		var source = File.getContent("tests/programs/generic-struct-class.hx"),
			start = source.indexOf("\tvar erased:"), end = source.indexOf("\tvar copy =", start);
		if (start < 0 || end < 0) throw "missing erased-view fixture";
		var staticSource = StringTools.replace(source.substring(0, start) + source.substring(end),
			"return box.get().number + owner.id;", "return box.get().number * 2;");
		var staticRuntime = new compiler.Compiler(null, compiler.runtime.CompilerIntrinsics.configuration());
		staticRuntime.addStandardLibrarySourceRoot("stdlib");
		staticRuntime.update("Main.hx", staticSource);
		var staticResult = GeneratedProgramRunner.exitCode(staticRuntime.compile("Main"));
		if (staticResult != 42) throw 'HashLink static generic value owner returned $staticResult';
		var runtime = new compiler.Compiler(null, compiler.runtime.CompilerIntrinsics.configuration());
		runtime.addStandardLibrarySourceRoot("stdlib");
		runtime.update("Main.hx", source);
		var compiled = runtime.compile("Main"), optimized = new compiler.ir.IrInterpreter(compiled.ir).run("main");
		if (optimized != 42) throw 'optimized generic value owner interpreter returned $optimized';
		var runtimeResult = GeneratedProgramRunner.exitCode(compiled);
		if (runtimeResult != 42) throw 'HashLink generic value owner returned $runtimeResult';
		incremental();
		incrementalTypeTests();
		incrementalInterfaceDispatch();
		incrementalRetainedOwner();
		checkWasmGcAllocations();
		Sys.println("PASS: generic owners retain concrete struct storage and identity through erased views");
	}

	static function checkCallbackAllocations():Void {
		var source = 'class CallbackCensus { static var value:hl.Abstract<"native_callback">; '
			+ 'public static function prepare(callback:hl.Abstract<"native_callback">):Void value=callback; '
			+ 'public static function perform(n:Int):Int { var count=0; for (_ in 0...n) if (identity(value)==value) count++; return count; } '
			+ 'static function identity(callback:hl.Abstract<"native_callback">):hl.Abstract<"native_callback"> return callback; } '
			+ 'function main():Int return 42;';
		for (inlineEnabled in [false, true]) for (target in [Wasm32, WasmGc]) {
			var program = Frontend.compile(source);
			compiler.ir.IrInliner.run(program, new compiler.ir.IrInliner.IrInlineCache(), inlineEnabled);
			var bytes = new compiler.backend.wasm.WasmBackend().compile(program, {target: target, debugNames: true,
				wasmMemoryStats: target == Wasm32, wasmGcAllocationCount: target == WasmGc,
				exports: ["CallbackCensus.prepare", "CallbackCensus.perform"]}).bytes,
				directory = Sys.getEnv("TMPDIR");
			if (directory == null || directory == "") directory = Sys.getCwd() + "/out/test-tools";
			if (!sys.FileSystem.exists(directory)) sys.FileSystem.createDirectory(directory);
			var path = '$directory/haxeon-callback-census-${Std.random(0x7fffffff)}.wasm';
			File.saveBytes(path, bytes);
			var script = 'const fs=require("fs"), i=new WebAssembly.Instance(new WebAssembly.Module(fs.readFileSync(process.argv[1]))); '
				+ 'i.exports.main(); i.exports["CallbackCensus.prepare"](123); '
				+ 'const counter=i.exports.__allocation_count||i.exports["haxeon.memory.allocation_count"]; '
				+ 'for(const n of [8,1024]) { const before=counter(), result=i.exports["CallbackCensus.perform"](n), count=counter()-before; '
				+ 'if(result!==n || count!==0) throw Error("n="+n+", result="+result+", allocations="+count); }';
			var process = new sys.io.Process("node", ["-e", script, path]);
			var error = process.stderr.readAll().toString(), status = process.exitCode();
			process.close(); sys.FileSystem.deleteFile(path);
			if (status != 0) throw 'Typed callback census failed on $target (inline=$inlineEnabled): $error';
		}
	}

	static function checkTypeHandleDynamic():Void {
		var builder = new compiler.ir.IrBuilder(),
			handle = builder.typeValue(I32), boxed = builder.toDyn(handle),
			tested = builder.call("__std_is_of_type", [boxed, builder.typeValue(TypeRef)], Bool),
			restored = builder.safeCast(boxed, TypeRef),
			matched = builder.call("__std_is_of_type", [builder.toDyn(builder.constInt(7)), restored], Bool),
			bad = builder.call("__std_is_of_type", [builder.toDyn(builder.constInt(12)), builder.typeValue(TypeRef)], Bool),
			passed = builder.createBlock(), failed = builder.createBlock(), badValue = builder.createBlock(), badType = builder.createBlock(),
			checkValue = builder.createBlock(), checkBad = builder.createBlock();
		builder.branch(tested, checkValue, failed);
		builder.select(checkValue); builder.branch(matched, checkBad, badValue);
		builder.select(checkBad); builder.branch(bad, badType, passed);
		builder.select(passed); builder.returnValue(builder.constInt(42));
		builder.select(failed); builder.returnValue(builder.constInt(1));
		builder.select(badValue); builder.returnValue(builder.constInt(2));
		builder.select(badType); builder.returnValue(builder.constInt(3));
		var program = new IrProgram("main");
		program.natives.push({name: "__std_is_of_type", library: "haxeon_runtime", symbol: "__std_is_of_type", arguments: [Dyn, TypeRef], result: Bool});
		program.functions.push(new compiler.ir.IrFunction("main", builder.arguments, I32, builder.blocks));
		for (isNull in [false, true]) {
			var invalid = new compiler.ir.IrBuilder(), wrong = isNull ? invalid.constNull(Dyn) : invalid.toDyn(invalid.constInt(12)),
				tryBody = invalid.createBlock(), handler = invalid.createBlock(), after = invalid.createBlock(),
				provenance = compiler.ir.SourceProvenance.generated("type-handle-test");
			invalid.currentBlock().instructions.push(new compiler.ir.SourceProvenance.Located(BeginTry(handler.id, after.id, false), provenance));
			invalid.jump(tryBody);
			invalid.select(tryBody);
			var recovered = invalid.safeCast(wrong, TypeRef), nullMatches = isNull ? invalid.equal(invalid.toDyn(recovered), wrong) : null;
			tryBody.instructions.push(new compiler.ir.SourceProvenance.Located(EndTry(handler.id, false), provenance));
			invalid.jump(after);
			invalid.select(handler);
			handler.instructions.push(new compiler.ir.SourceProvenance.Located(Catch(new IrValue(1000000, "$caught", Dyn)), provenance));
			invalid.returnValue(invalid.constInt(isNull ? 1 : 42));
			invalid.select(after);
			if (isNull) {
				var matchedNull = invalid.createBlock(), mismatchedNull = invalid.createBlock();
				invalid.branch(nullMatches, matchedNull, mismatchedNull);
				invalid.select(matchedNull); invalid.returnValue(invalid.constInt(42));
				invalid.select(mismatchedNull); invalid.returnValue(invalid.constInt(1));
			} else invalid.returnValue(invalid.constInt(1));
			program.functions.push(new compiler.ir.IrFunction(isNull ? "nullHandle" : "invalidHandle", [], I32, invalid.blocks));
		}
		if (new compiler.ir.IrInterpreter(program).run() != 42) throw "interpreter lost a Dynamic type handle";
		if (new compiler.ir.IrInterpreter(program).run("invalidHandle") != 42) throw "interpreter accepted an invalid type handle";
		if (new compiler.ir.IrInterpreter(program).run("nullHandle") != 42) throw "interpreter lost a null type handle";
		var hlProgram = new IrProgram("__entry"), entry = new compiler.ir.IrBuilder();
		hlProgram.natives = program.natives.copy();
		hlProgram.natives.push({name: "__exit", library: "std", symbol: "sys_exit", arguments: [I32], result: Void});
		var valid = entry.equal(entry.call("main", [], I32), entry.constInt(42)), validBlock = entry.createBlock(), invalidBlock = entry.createBlock();
		entry.branch(valid, validBlock, invalidBlock);
		entry.select(validBlock);
		var validInvalid = entry.equal(entry.call("invalidHandle", [], I32), entry.constInt(42)), nullBlock = entry.createBlock();
		entry.branch(validInvalid, nullBlock, invalidBlock);
		entry.select(nullBlock); entry.call("__exit", [entry.call("nullHandle", [], I32)], Void); entry.returnValue(entry.constVoid());
		entry.select(invalidBlock); entry.call("__exit", [entry.constInt(1)], Void); entry.returnValue(entry.constVoid());
		hlProgram.functions = program.functions.concat([new compiler.ir.IrFunction("__entry", [], Void, entry.blocks)]);
		var hashlink = new compiler.backend.hl.HlBackend().compile(hlProgram, {target: HashLink, debugNames: true});
		var hlDirectory = Sys.getEnv("TMPDIR");
		if (hlDirectory == null || hlDirectory == "") hlDirectory = Sys.getCwd() + "/out/test-tools";
		if (!sys.FileSystem.exists(hlDirectory)) sys.FileSystem.createDirectory(hlDirectory);
		var hlPath = '$hlDirectory/haxeon-type-handle-${Std.random(0x7fffffff)}.hl';
		File.saveBytes(hlPath, hashlink.bytes);
		var hlStatus = Sys.command(Sys.getEnv("HAXEON_HASHLINK_DIR") + "/hl", [hlPath]);
		sys.FileSystem.deleteFile(hlPath);
		if (hlStatus != 42) throw 'HashLink lost a Dynamic type handle: $hlStatus';
		for (target in [Wasm32, WasmGc]) {
			var bytes = new compiler.backend.wasm.WasmBackend().compile(program, {target: target, debugNames: true, exports: ["invalidHandle", "nullHandle"]}).bytes,
				directory = Sys.getEnv("TMPDIR");
			if (directory == null || directory == "") directory = Sys.getCwd() + "/out/test-tools";
			if (!sys.FileSystem.exists(directory)) sys.FileSystem.createDirectory(directory);
			var path = '$directory/haxeon-type-handle-${Std.random(0x7fffffff)}.wasm';
			File.saveBytes(path, bytes);
			var script = 'const fs=require("fs"), m=new WebAssembly.Module(fs.readFileSync(process.argv[1])); '
				+ 'const i=new WebAssembly.Instance(m,{haxeon_runtime:{},std:{sys_exit(){}}}); const result=i.exports.main(), invalid=i.exports.invalidHandle(), nil=i.exports.nullHandle(); '
				+ 'if(result!==42 || invalid!==42 || nil!==42) { console.error("result="+result+", invalid="+invalid+", null="+nil); process.exit(1); }';
			var process = new sys.io.Process("node", ["-e", script, path]);
			var error = process.stderr.readAll().toString(), status = process.exitCode();
			process.close(); sys.FileSystem.deleteFile(path);
			if (status != 0) throw 'Dynamic type handle failed on $target: $error';
		}
	}

	static function checkWasmGcAllocations():Void {
		var source = 'class Owner { public function new() {} } '
			+ 'struct Value { public var number:Int; public var owner:Owner; public function new(number:Int, owner:Owner) '
			+ '{ this.number=number; this.owner=owner; } } '
			+ 'class Box<T> { public var value:T; public function new(value:T) this.value=value; '
			+ 'public function get():T return value; public function set(value:T):Void this.value=value; } '
			+ 'class Census { public static var owner:Owner; public static var box:Box<Value>; public static var read:Void->Value; '
			+ 'public static var measure:Value->Int; static function number(value:Value):Int return value.number; '
			+ 'public static function prepare():Void { owner=new Owner(); box=new Box<Value>(new Value(0,owner)); read=box.get; measure=number; '
			+ 'var escaped:Dynamic=read; if(escaped()==null) throw "missing"; var restored:Void->Value=cast escaped; '
			+ 'if(restored().owner!=owner) throw "bad restored closure"; var escapedMeasure:Dynamic=measure; '
			+ 'if(escapedMeasure(new Value(17,owner))!=17) throw "bad argument"; var restoredMeasure:Value->Int=cast escapedMeasure; '
			+ 'if(restoredMeasure(new Value(19,owner))!=19) throw "bad restored argument"; var empty:Void->Value=null; '
			+ 'var erasedEmpty:Dynamic=empty; if(erasedEmpty!=null) throw "non-null"; var restoredEmpty:Void->Value=cast erasedEmpty; '
			+ 'if(restoredEmpty!=null) throw "bad restored null"; } '
			+ 'public static function perform(n:Int):Int { var sum=0; var operation=read; var metric=measure; for(i in 0...n) { box.set(new Value(i,owner)); '
			+ 'var value=operation(); if(value.owner!=owner) return -1; sum+=metric(value); } return sum; } '
			+ 'public static function direct(n:Int):Int { var sum=0; for(i in 0...n) { box.set(new Value(i,owner)); var value=box.get(); '
			+ 'if(value.owner!=owner) return -1; sum+=value.number; } return sum; } '
			+ 'public static function field(n:Int):Int { var sum=0; for(i in 0...n) { box.value=new Value(i,owner); var value=box.value; '
			+ 'if(value.owner!=owner) return -1; sum+=value.number; } return sum; } } function main():Int return 42;';
		for (inlineEnabled in [false, true]) {
			var program = Frontend.compile(source);
			compiler.ir.IrValueArrayProgramRewrite.rewriteAll(program, 32, WasmGc);
			compiler.ir.IrValueConstructors.rewrite(program);
			compiler.ir.IrValuePhiScalarization.rewrite(program);
			compiler.ir.IrScalarArguments.rewrite(program, true);
			compiler.ir.IrValuePhiScalarization.rewrite(program);
			var objects = compiler.ir.IrObjectTable.of([for (object in program.objects) object.name => object]);
			program.functions = [for (fn in program.functions) compiler.ir.IrScalarReplacement.rewrite(fn, objects, false, true)];
			compiler.ir.IrNullableScalarFlow.rewrite(program);
			compiler.ir.IrInliner.run(program, new compiler.ir.IrInliner.IrInlineCache(), inlineEnabled);
			var bytes = new compiler.backend.wasm.WasmBackend().compile(program, {target: WasmGc, debugNames: true,
				wasmGcAllocationCount: true, exports: ["Census.prepare", "Census.perform", "Census.direct", "Census.field"]}).bytes;
			var directory = Sys.getEnv("TMPDIR");
			if (directory == null || directory == "") directory = Sys.getCwd() + "/out/test-tools";
			if (!sys.FileSystem.exists(directory)) sys.FileSystem.createDirectory(directory);
			var path = '$directory/haxeon-generic-owner-census-${Std.random(0x7fffffff)}.wasm';
			File.saveBytes(path, bytes);
			var script = 'const fs=require("fs"), i=new WebAssembly.Instance(new WebAssembly.Module(fs.readFileSync(process.argv[1]))); '
				+ 'i.exports.main(); i.exports["Census.prepare"](); let bad=[]; for(const operation of ["field","direct","perform"]) for(const n of [8,1024]) { const before=i.exports.__allocation_count(); '
				+ 'const result=i.exports["Census."+operation](n), count=i.exports.__allocation_count()-before; '
				+ 'if(result!==n*(n-1)/2 || count!==0) bad.push(operation+" n="+n+", result="+result+", allocations="+count); } if(bad.length) throw Error(bad.join("; "));';
			var process = new sys.io.Process("node", ["-e", script, path]);
			var error = process.stderr.readAll().toString(), status = process.exitCode();
			process.close();
			sys.FileSystem.deleteFile(path);
			if (status != 0) throw 'Wasm GC generic owner allocation census (inline=$inlineEnabled): $error';
		}
	}

	static function incremental():Void {
		var compiler = new compiler.Compiler(null, compiler.runtime.CompilerIntrinsics.configuration());
		compiler.update("Payload.hx", 'struct Payload { public var number:Int; public var text:String; '
			+ 'public function new(number:Int, text:String) { this.number=number; this.text=text; } }');
		var box = 'class Box<T> { public var value:T; public function new(value:T) this.value=value; '
			+ 'public function get():T return value; public function tag():Int return 1; }';
		compiler.update("Box.hx", box);
		compiler.update("Derived.hx", 'class Derived<T> extends Box<T> { public function new(value:T) super(value); '
			+ 'override public function tag():Int return super.tag(); }');
		compiler.update("Main.hx", 'class Main { static function main():Int { var b:Box<Payload>=new Derived<Payload>(new Payload(41,"x")); '
			+ 'return b.get().number+b.tag(); } }');
		for (expected in [42, 43, 42]) {
			compiler.update("Box.hx", expected == 43 ? StringTools.replace(box, "return 1", "return 2") : box);
			var actual = GeneratedProgramRunner.exitCode(compiler.compile("Main"));
			if (actual != expected) throw 'specialized generic owner after edit: expected $expected, got $actual';
		}
	}

	static function incrementalTypeTests():Void {
		var compiler = new compiler.Compiler(null, compiler.runtime.CompilerIntrinsics.configuration());
		compiler.update("Value.hx", 'struct Value { public var number:Int; public function new(number:Int) this.number=number; }');
		compiler.update("Box.hx", 'class Box<T> { public var value:T; public function new(value:T) this.value=value; }');
		compiler.update("Check.hx", 'class Check { public static function check(value:Dynamic):Bool '
			+ 'return Std.isOfType(value,Box) && Std.isExactType(value,Box); }');
		compiler.update("Main.hx", 'class Main { static function anchor():Value return new Value(0); '
			+ 'static function main():Int return Check.check(Maker.make()) ? 42 : 1; }');
		for (expression in ['new Box<Int>(3)', 'new Box<Value>(new Value(3))', 'new Box<Int>(3)']) {
			compiler.update("Maker.hx", 'class Maker { public static function make():Dynamic return $expression; }');
			var compiled = compiler.compile("Main"), actual = GeneratedProgramRunner.exitCode(compiled);
			if (actual != 42) throw 'generic runtime type test after layout edit returned $actual';
			var found = false;
			for (object in compiled.ir.objects)
				if (StringTools.startsWith(object.name, '$' + 'generic:$' + 'owner:Box')
					&& object.name.indexOf('class:Value') >= 0) found = true;
			if (found != (expression.indexOf('Box<Value>') >= 0))
				throw 'stale generic owner after edit: $expression';
			var interpreted = new compiler.ir.IrInterpreter(compiled.ir).run("Main.main");
			if (interpreted != 42) throw 'interpreted generic runtime type test after layout edit returned $interpreted';
		}
	}

	static function incrementalInterfaceDispatch():Void {
		var compiler = new compiler.Compiler(null, compiler.runtime.CompilerIntrinsics.configuration());
		compiler.update("Reader.hx", 'interface Reader<T> { function read():T; }');
		compiler.update("Use.hx", 'class Use { public static function read(value:Reader<Int>):Int return value.read(); }');
		compiler.update("Main.hx", 'class Main { static function main():Int return Use.read(Maker.make()); }');
		for (number in [41, 42, 41]) {
			var implementation = number == 42 ? "SecondReader" : "FirstReader";
			compiler.update("Maker.hx", 'class $implementation implements Reader<Int> { public function new() {} '
				+ 'public function read():Int return $number; } '
				+ 'class Maker { public static function make():Reader<Int> return new $implementation(); }');
			var compiled = compiler.compile("Main"), actual = GeneratedProgramRunner.exitCode(compiled),
				interpreted = new compiler.ir.IrInterpreter(compiled.ir).run("Main.main");
			if (actual != number || interpreted != number)
				throw 'typed interface dispatch after implementation edit: expected $number, got $actual and $interpreted';
		}
	}

	static function incrementalRetainedOwner():Void {
		var compiler = new compiler.Compiler(null, compiler.runtime.CompilerIntrinsics.configuration());
		compiler.update("Value.hx", 'struct Value { public var number:Int; public function new(number:Int) this.number=number; }');
		compiler.update("Box.hx", 'class Box<T> { public var value:T; public function new(value:T) this.value=value; }');
		compiler.update("Keep.hx", 'class Keep { public static function make():Dynamic { '
			+ 'var create=()->new Box<Value>(new Value(3)); return create(); } }');
		compiler.update("Main.hx", 'class Main { static function main():Int '
			+ 'return Std.isOfType(Keep.make(),Box) && Maker.number()==2 ? 42 : 1; }');
		for (number in [1, 2]) {
			compiler.update("Maker.hx", 'class Maker { public static function number():Int return $number; }');
			var compiled = compiler.compile("Main"), expected = number == 2 ? 42 : 1,
				actual = GeneratedProgramRunner.exitCode(compiled);
			if (actual != expected) throw 'unchanged closure lost its generic owner: expected $expected, got $actual';
		}
	}
}
