import compiler.Frontend;
import compiler.ir.Ir;
import sys.io.File;

/** Generic class fields and methods use the concrete value representation, including inherited owners. */
class GenericStructOwnerMain {
	static function main():Void {
		var referenceRuntime = new compiler.Compiler(null, compiler.runtime.CompilerIntrinsics.configuration());
		referenceRuntime.addSourceRoot("stdlib");
		referenceRuntime.update("Main.hx", File.getContent("tests/programs/generic-erased-reference-checks.hx"));
		if (new compiler.ir.IrInterpreter(referenceRuntime.compile("Main").ir).run("main") != 42)
			throw "erased reference writes did not preserve checked value semantics in the interpreter";
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
		staticRuntime.addSourceRoot("stdlib");
		staticRuntime.update("Main.hx", staticSource);
		var staticResult = GeneratedProgramRunner.exitCode(staticRuntime.compile("Main"));
		if (staticResult != 42) throw 'HashLink static generic value owner returned $staticResult';
		var runtime = new compiler.Compiler(null, compiler.runtime.CompilerIntrinsics.configuration());
		runtime.addSourceRoot("stdlib");
		runtime.update("Main.hx", source);
		var compiled = runtime.compile("Main"), optimized = new compiler.ir.IrInterpreter(compiled.ir).run("main");
		if (optimized != 42) throw 'optimized generic value owner interpreter returned $optimized';
		var runtimeResult = GeneratedProgramRunner.exitCode(compiled);
		if (runtimeResult != 42) throw 'HashLink generic value owner returned $runtimeResult';
		incremental();
		incrementalTypeTests();
		incrementalRetainedOwner();
		checkWasmGcAllocations();
		Sys.println("PASS: generic owners retain concrete struct storage and identity through erased views");
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
