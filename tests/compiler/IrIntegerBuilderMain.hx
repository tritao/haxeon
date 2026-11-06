import compiler.ir.Ir.IrProgram;
import compiler.ir.Ir.IrType;
import compiler.ir.IrBuilder;
import compiler.ir.IrFunction;
import compiler.ir.IrInterpreter;
import compiler.ir.IrVerifier;
import compiler.backend.Backend.BackendTarget;
import compiler.backend.hl.HlBackend;
import compiler.backend.wasm.WasmBackend;

class IrIntegerBuilderMain {
	static function main():Void {
		var builder = new IrBuilder();
		var remainder = builder.mod(builder.constInt(13, I64), builder.constInt(5, I64));
		var left = builder.shiftLeft(remainder, builder.constInt(4));
		var combined = builder.bitOr(left, builder.constInt(2, I64));
		var masked = builder.bitAnd(combined, builder.constInt(63, I64));
		var toggled = builder.bitXor(masked, builder.constInt(8, I64));
		var signed = builder.shiftRight(toggled, builder.constInt(1));
		var unsigned = builder.unsignedShiftRight(signed, builder.constInt(1));
		builder.returnValue(builder.add(unsigned, builder.constInt(28, I64)));
		var program = new IrProgram("main");
		program.functions = [new IrFunction("main", builder.arguments, I64, builder.blocks)];
		IrVerifier.verify(program);
		var actual:haxe.Int64 = cast new IrInterpreter(program).run();
		if (actual != haxe.Int64.ofInt(42)) throw "64-bit integer builder operations gave the wrong result";
		if (new HlBackend().compile(program, {target: HashLink, debugNames: true}).bytes.length == 0
			|| new WasmBackend().compile(program, {target: Wasm32, debugNames: true}).bytes.length == 0
			|| new WasmBackend().compile(program, {target: WasmGc, debugNames: true}).bytes.length == 0)
			throw "64-bit integer builder operations must lower on each backend";
		checkWideArithmetic();
		checkSourceConstructors();
		Sys.println("PASS: IR builder preserves integer widths through modulo, bitwise operations and shifts");
	}
	static function checkSourceConstructors():Void {
		var compiler = new compiler.Compiler(null, compiler.runtime.CompilerIntrinsics.configuration());
		compiler.addSourceRoot("stdlib");
		compiler.update("WideConstructors.hx", 'function main():Int { '
			+ 'var wide = haxe.Int64.make(1, -1); var negative = haxe.Int64.ofInt(-7); '
			+ 'return haxe.Int64.toInt(haxe.Int64.ushr(wide, 32)) == 1 '
			+ '&& haxe.Int64.toInt(wide) == -1 && haxe.Int64.toInt(negative) == -7 '
			+ '&& haxe.Int64.toInt(haxe.Int64.ushr(negative, 32)) == -1 ? 42 : 1; }');
		var compiled = compiler.compile("WideConstructors");
		if (new IrInterpreter(compiled.ir).run("main") != 42)
			throw "IR interpreter lost a source Int64 constructor word or sign extension";
		if (GeneratedProgramRunner.exitCode(compiled) != 42)
			throw "Source Int64 constructors disagree with HashLink";
	}

	static function checkWideArithmetic():Void {
		var b = new IrBuilder(), checks:Array<compiler.ir.Ir.IrValue> = [];
		var high = b.shiftLeft(b.constInt(1, I64), b.constInt(40)), low = b.shiftLeft(b.constInt(1, I64), b.constInt(8));
		checks.push(b.equal(b.equal(high, low), b.constBool(false)));
		checks.push(b.equal(b.unsignedShiftRight(high, b.constInt(32)), low));
		var unsigned = b.unsignedShiftRight(b.constInt(-1, I64), b.constInt(32));
		checks.push(b.equal(b.unsignedShiftRight(unsigned, b.constInt(32)), b.constInt(0, I64)));
		checks.push(b.equal(b.sub(b.add(high, b.constInt(9, I64)), high), b.constInt(9, I64)));
		checks.push(b.less(b.sub(b.constInt(0, I64), high), b.constInt(0, I64)));
		checks.push(b.lessEqual(low, high));
		checks.push(b.equal(b.div(b.mul(high, b.constInt(3, I64)), high), b.constInt(3, I64)));
		checks.push(b.equal(b.mod(high, b.constInt(7, I64)), b.constInt(2, I64)));
		checks.push(b.equal(b.div(b.constInt(-7, I64), b.constInt(2, I64)), b.constInt(-3, I64)));
		checks.push(b.equal(b.mod(b.constInt(-7, I64), b.constInt(2, I64)), b.constInt(-1, I64)));
		checks.push(b.equal(b.intToInt64(b.constInt(-1)), b.constInt(-1, I64)));
		checks.push(b.call("__dynamic_equal", [b.toDyn(high), b.toDyn(b.shiftLeft(b.constInt(1, I64), b.constInt(40)))], Bool));
		var array = b.call("__array_alloc_i64", [b.constInt(1)], compiler.ir.Ir.IrType.Array(I64));
		checks.push(b.equal(b.arrayGet(array, b.constInt(0), I64), b.constInt(0, I64)));
		var owner = b.newObject("WideDefault");
		checks.push(b.equal(b.fieldGet(owner, "word", I64), b.constInt(0, I64)));
		for (floating in [-12.5, -0.0, Math.NaN]) {
			var bits = b.call("__f64_to_i64_bits", [b.constFloat(floating)], I64);
			var restored = b.call("__i64_to_f64_bits", [bits], F64);
			checks.push(b.equal(b.call("__f64_to_i64_bits", [restored], I64), bits));
		}
		var failed = b.createBlock();
		for (check in checks) {
			var next = b.createBlock(); b.branch(check, next, failed); b.select(next);
		}
		b.returnValue(b.constInt(42)); b.select(failed); b.returnValue(b.constInt(1));
		var program = new IrProgram("main");
		program.objects = [{name: "WideDefault", isValue: false, base: null, interfaces: [], methods: [], fields: [{name: "word", type: I64}]}];
		program.functions = [new IrFunction("main", b.arguments, I32, b.blocks)];
		var entry = new IrBuilder(); entry.call("__exit", [entry.call("main", [], I32)], Void); entry.returnValue(entry.constVoid());
		program.functions.push(new IrFunction("entry", entry.arguments, Void, entry.blocks));
		program.natives = [
			{name: "__array_alloc_i64", library: "haxeon_runtime", symbol: "__array_alloc_i64", arguments: [I32], result: compiler.ir.Ir.IrType.Array(I64)},
			{name: "__dynamic_equal", library: "haxeon_runtime", symbol: "__dynamic_equal", arguments: [Dyn, Dyn], result: Bool},
			{name: "__f64_to_i64_bits", library: "haxeon_runtime", symbol: "__f64_to_i64_bits", arguments: [F64], result: I64},
			{name: "__i64_to_f64_bits", library: "haxeon_runtime", symbol: "__i64_to_f64_bits", arguments: [I64], result: F64},
			{name: "__exit", library: "std", symbol: "sys_exit", arguments: [I32], result: Void}
		];
		IrVerifier.verify(program);
		if (new IrInterpreter(program).run() != 42) throw "IR interpreter lost high words, signed arithmetic or floating payload bits";
		var root = Sys.getEnv("TMPDIR"), hashlink = Sys.getEnv("HAXEON_HASHLINK_DIR");
		if (root == null) root = "/tmp";
		for (target in [HashLink, Wasm32, WasmGc]) {
			var path = root + '/wide-arithmetic-' + Std.random(0x7fffffff) + (target == HashLink ? ".hl" : ".wasm");
			try {
				program.entryPoint = target == HashLink ? "entry" : "main";
				var bytes = target == HashLink ? new HlBackend().compile(program, {target: target, debugNames: true}).bytes
					: new WasmBackend().compile(program, {target: target, debugNames: true}).bytes;
				sys.io.File.saveBytes(path, bytes);
				var command = target == HashLink ? (hashlink == null ? "scripts/hl" : hashlink + "/hl") : "node";
				var js = 'const fs=require("fs");const e=new WebAssembly.Instance(new WebAssembly.Module(fs.readFileSync(process.argv[1]))).exports;if(e.main()!==42)throw Error("wide arithmetic failed");';
				var process = new sys.io.Process(command, target == HashLink ? [path] : ["-e", js, path]);
				var error = process.stderr.readAll().toString() + process.stdout.readAll().toString(), status = process.exitCode(); process.close();
				if (status != (target == HashLink ? 42 : 0)) throw '$target wide arithmetic failed: $status $error';
			} catch (error:Dynamic) {
				if (sys.FileSystem.exists(path)) sys.FileSystem.deleteFile(path);
				throw error;
			}
			sys.FileSystem.deleteFile(path);
		}
		Sys.println("PASS: full-width integer arithmetic and Float bit round trips agree on all targets");
	}

}
