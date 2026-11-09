import compiler.Frontend;
import compiler.ir.Ir;
import sys.io.File;

/** Managed values need their own generic ABI while ordinary references continue to share one. */
class GenericStructFunctionMain {
	static function main():Void {
		var source = File.getContent("tests/programs/generic-struct-functions.hx");
		var program = Frontend.compile(source);
		var point = false, other = false, reference = false, constrained = false;
		for (fn in program.functions) {
			for (block in fn.blocks) for (instruction in block.instructions) switch instruction.value {
				case ToDyn(_, value) if (Type.enumEq(value.type, Obj("ManagedPoint")) || Type.enumEq(value.type, Obj("ManagedOther"))):
					throw "a generic struct call crossed an erased Dynamic ABI";
				default:
			}
			if (StringTools.startsWith(fn.name, "$generic:identity[layout]")) {
				if (fn.arguments.length != 1 || !Type.enumEq(fn.arguments[0].type, fn.result))
					throw "generic value identity lost its concrete ABI";
				switch fn.result {
					case Obj("ManagedPoint"): point = true;
					case Obj("ManagedOther"): other = true;
					default: throw "unexpected layout-specialized identity: " + fn.name;
				}
			} else if (StringTools.startsWith(fn.name, "$generic:identity[shape]")) {
				if (!Type.enumEq(fn.arguments[0].type, Dyn) || !Type.enumEq(fn.result, Dyn))
					throw "ordinary reference identity should retain the shared ABI";
				reference = true;
			} else if (StringTools.startsWith(fn.name, "$generic:measure[constrained]")) {
				constrained = Type.enumEq(fn.arguments[0].type, Obj("ManagedPoint"));
			}
		}
		if (!point || !other || !reference || !constrained)
			throw 'missing specialization: point=$point other=$other reference=$reference constrained=$constrained';
		if (new compiler.ir.IrInterpreter(program).run("main") != 42)
			throw "generic struct value semantics failed";
		var incremental = new compiler.Compiler(null, compiler.runtime.CompilerIntrinsics.configuration());
		for (expected in [42, 41, 42]) {
			incremental.update("Main.hx", expected == 41 ? StringTools.replace(source, "? 42 : 1", "? 41 : 1") : source);
			if (GeneratedProgramRunner.exitCode(incremental.compile("Main")) != expected)
				throw "generic struct specialization failed after an incremental edit";
		}
		checkWasmGcAllocations();
		Sys.println("PASS: generic functions retain distinct managed value representations");
	}

	static function checkWasmGcAllocations():Void {
		var source = 'class Owner { public function new() {} } '
			+ 'struct Value { public var number:Int; public var owner:Owner; public function new(number:Int, owner:Owner) '
			+ '{ this.number=number; this.owner=owner; } } function identity<T>(value:T):T return value; '
			+ 'function apply<T>(value:T, operation:T->Int):Int return operation(value); '
			+ 'class Census { public static var owner:Owner; public static var operation:Value->Int; '
			+ 'static function number(value:Value):Int return value.number; '
			+ 'public static function prepare():Void { owner=new Owner(); operation=number; } '
			+ 'public static function perform(n:Int):Int { var sum=0; for(i in 0...n) { var value=identity(new Value(i,owner)); '
			+ 'if(value.owner!=owner) return -1; sum+=apply(value,operation); } return sum; } } function main():Int return 42;';
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
			compiler.ir.IrInliner.run(program, new compiler.ir.IrInliner.IrInlineCache(), compiler.ir.TargetProfile.wasm, inlineEnabled);
			var bytes = new compiler.backend.wasm.WasmBackend().compile(program, {target: WasmGc, debugNames: true,
				wasmGcAllocationCount: true, exports: ["Census.prepare", "Census.perform"]}).bytes;
			var directory = Sys.getCwd() + "/out/test-tools";
			if (!sys.FileSystem.exists(directory)) sys.FileSystem.createDirectory(directory);
			var path = directory + "/generic-struct-function-census-" + Std.random(0x7fffffff) + ".wasm";
			File.saveBytes(path, bytes);
			var script = 'const fs=require("fs"), i=new WebAssembly.Instance(new WebAssembly.Module(fs.readFileSync(process.argv[1]))); '
				+ 'i.exports.main(); i.exports["Census.prepare"](); for(const n of [8,1024]) { const before=i.exports.__allocation_count(); '
				+ 'const result=i.exports["Census.perform"](n), count=i.exports.__allocation_count()-before; '
				+ 'if(result!==n*(n-1)/2 || count!==0) throw Error("n="+n+", result="+result+", allocations="+count); }';
			var process = new sys.io.Process("node", ["-e", script, path]);
			var error = process.stderr.readAll().toString(), status = process.exitCode();
			process.close();
			sys.FileSystem.deleteFile(path);
			if (status != 0) throw 'Wasm GC generic value allocation census (inline=$inlineEnabled): $error';
		}
	}
}
