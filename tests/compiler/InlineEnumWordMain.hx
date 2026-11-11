import compiler.backend.Backend.BackendTarget;
import compiler.ir.Ir;
import compiler.ir.IrBuilder;
import compiler.ir.IrFunction;
import compiler.ir.IrInlineEnumWordAccess;
import compiler.ir.IrInterpreter;
import compiler.ir.IrValueLaneLayout.IrValueLaneSlot;

/** Execute packed payload access, including fields split between two words, on every runtime. */
class InlineEnumWordMain {
	static function slot(index:Int, offset:Int, width:Int, signed:Bool):IrValueLaneSlot
		return {path: [], type: I32, isPresence: false, nullablePayload: false,
			index: index, isReference: false, bitOffset: offset, bitWidth: width, signed: signed};

	static function main():Void {
		for (bits in [32, 64]) for (inlineEnabled in [false, true]) check(bits, inlineEnabled);
		Sys.println("PASS: enum word access preserves Float32 bits and allocates nothing on all targets");
	}

	static function check(bits:Int, inlineEnabled:Bool):Void {
		var root = Sys.getEnv("TMPDIR");
		if (root == null) root = "/tmp";
		var stem = root + "/inline-enum-words-" + bits + "-" + inlineEnabled + "-" + Std.random(0x7fffffff);
		var builder = new IrBuilder(), owner = builder.newObject("PayloadWords"), words = new IrInlineEnumWordAccess(bits);
		var wordType:IrType = bits == 64 ? I64 : I32;
		builder.fieldSet(owner, "scalar0", builder.constInt(0, wordType));
		builder.fieldSet(owner, "scalar1", builder.constInt(0, wordType));
		var cross = slot(0, bits - 8, 16, false), signed = slot(0, 8, 8, true), complete:IrValueLaneSlot = {path: [], type: wordType, isPresence: false, nullablePayload: false,
			index: 2, isReference: false, bitOffset: 0, bitWidth: bits, signed: true};
		words.write(builder, owner, cross, builder.constInt(0x1234));
		words.write(builder, owner, signed, builder.constInt(-2));
		// A full-word store must not read an uninitialized old word or mask the new one.
		words.write(builder, owner, complete, builder.constInt(-2000000000, wordType));
		var left = words.read(builder, owner, cross), right = words.read(builder, owner, signed);
		var checks = [builder.equal(builder.add(left, right), builder.constInt(0x1232)),
			builder.equal(words.read(builder, owner, complete), builder.constInt(-2000000000, wordType))];
		var boolean:IrValueLaneSlot = {path: [], type: Bool, isPresence: false, nullablePayload: false,
			index: 5, isReference: false, bitOffset: 3, bitWidth: 1, signed: false};
		builder.fieldSet(owner, "scalar5", builder.constInt(0, wordType));
		words.write(builder, owner, boolean, builder.constBool(true));
		checks.push(words.read(builder, owner, boolean));
		words.write(builder, owner, boolean, builder.constBool(false));
		checks.push(builder.equal(words.read(builder, owner, boolean), builder.constBool(false)));
		var f32:IrValueLaneSlot = {path: [], type: F32, isPresence: false, nullablePayload: false,
			index: 3, isReference: false, bitOffset: bits - 8, bitWidth: 32, signed: false};
		builder.fieldSet(owner, "scalar3", builder.constInt(0, wordType));
		builder.fieldSet(owner, "scalar4", builder.constInt(0, wordType));
		for (number in [-12.5, -0.0, 0.1, 1.401298464324817e-45, Math.NaN, Math.POSITIVE_INFINITY]) {
			var input = builder.constFloat(number, F32), originalBits = builder.call("__f32_to_i32_bits", [input], I32);
			if (!Math.isNaN(number)) checks.push(builder.equal(originalBits, builder.constInt(haxe.io.FPHelper.floatToI32(number))));
			words.write(builder, owner, f32, input);
			checks.push(builder.equal(builder.call("__f32_to_i32_bits", [words.read(builder, owner, f32)], I32), originalBits));
		}
		if (bits == 64) {
			var wide:IrValueLaneSlot = {path: [], type: I64, isPresence: false, nullablePayload: false,
				index: 3, isReference: false, bitOffset: 24, bitWidth: 64, signed: true};
			builder.fieldSet(owner, "scalar3", builder.constInt(0, I64));
			builder.fieldSet(owner, "scalar4", builder.constInt(0, I64));
			var expected = builder.add(builder.shiftLeft(builder.constInt(1, I64), builder.constInt(50)), builder.constInt(0x123456, I64));
			words.write(builder, owner, wide, expected);
			checks.push(builder.equal(words.read(builder, owner, wide), expected));
			var floating:IrValueLaneSlot = {path: [], type: F64, isPresence: false, nullablePayload: false,
				index: 2, isReference: false, bitOffset: 0, bitWidth: 64, signed: false};
			for (number in [-12.5, -0.0, Math.NaN]) {
				var value = builder.constFloat(number), expectedBits = builder.call("__f64_to_i64_bits", [value], I64);
				words.write(builder, owner, floating, value);
				checks.push(builder.equal(builder.call("__f64_to_i64_bits", [words.read(builder, owner, floating)], I64), expectedBits));
			}
		}
		var no = builder.createBlock();
		for (check in checks) {
			var next = builder.createBlock(); builder.branch(check, next, no); builder.select(next);
		}
		builder.returnValue(builder.constInt(42));
		builder.select(no); builder.returnValue(builder.constInt(1));
		var program = new IrProgram("main");
		program.objects = [{name: "PayloadWords", isValue: true, base: null, interfaces: [], methods: [],
			fields: [for (index in 0...6) {name: 'scalar$index', type: wordType}]}];
		program.functions = [new IrFunction("main", builder.arguments, I32, builder.blocks, Ordinary)];
		var entry = new IrBuilder(), warm = entry.call("main", [], I32), captures:Array<String> = [];
		for (n in [8, 1024]) {
			var path = stem + "-census-" + n + ".json";
			captures.push(path);
			entry.call("reset", [], Void);
			entry.call("start", [entry.constInt(0)], Void);
			for (_ in 0...n) entry.call("main", [], I32);
			entry.call("stop", [], Void);
			entry.call("dump", [entry.constString(path)], Void);
		}
		entry.call("__exit", [warm], Void);
		entry.returnValue(entry.constVoid());
		program.functions.push(new IrFunction("entry", entry.arguments, Void, entry.blocks, Ordinary));
		program.natives = IrInlineEnumWordAccess.natives().concat([
			{name: "start", library: "std", symbol: "gc_census_start", arguments: [I32], result: Void},
			{name: "stop", library: "std", symbol: "gc_census_stop", arguments: [], result: Void},
			{name: "reset", library: "std", symbol: "gc_census_reset", arguments: [], result: Void},
			{name: "dump", library: "haxeon_runtime", symbol: "__gc_census_dump", arguments: [Bytes], result: Void},
			{name: "__exit", library: "std", symbol: "sys_exit", arguments: [I32], result: Void}
		]);
		var table = compiler.ir.IrObjectTable.of([for (object in program.objects) object.name => object]);
		program.functions = [for (fn in program.functions) compiler.ir.IrScalarReplacement.rewrite(fn, table, false)];
		compiler.ir.IrInliner.run(program, new compiler.ir.IrInliner.IrInlineCache(), compiler.ir.TargetProfile.wasm, inlineEnabled);
		compiler.ir.IrVerifier.verify(program);
		if (new IrInterpreter(program).run() != 42) throw "packed enum payload changed its bits";
		for (target in [HashLink, Wasm32, WasmGc]) {
			var path = stem + '-$target' + (target == HashLink ? ".hl" : ".wasm");
			try {
				program.entryPoint = target == HashLink ? "entry" : "main";
				var bytes = target == HashLink
					? new compiler.backend.hl.HlBackend().compile(program, {target: target, debugNames: true}).bytes
					: new compiler.backend.wasm.WasmBackend().compile(program, {target: target, debugNames: true, wasmGcAllocationCount: target == WasmGc, wasmMemoryStats: target == Wasm32}).bytes;
				sys.io.File.saveBytes(path, bytes);
				var vm = Sys.getEnv("HAXEON_HASHLINK_DIR");
				var command = target == HashLink ? (vm == null ? "scripts/hl" : vm + "/hl") : "node";
				var script = 'const fs=require("fs");const e=new WebAssembly.Instance(new WebAssembly.Module(fs.readFileSync(process.argv[1]))).exports;const c=e.__allocation_count||e["haxeon.memory.allocation_count"];e.main();for(const n of [8,1024]){const before=c();for(let i=0;i<n;i++)if(e.main()!==42)throw Error("wrong enum payload bits");if(c()!==before)throw Error("F32 payload allocated");}';
				var process = new sys.io.Process(command, target == HashLink ? [path] : ["-e", script, path]);
				var output = process.stdout.readAll().toString(), error = process.stderr.readAll().toString(), status = process.exitCode(); process.close();
				if (status != (target == HashLink ? 42 : 0)) throw '$target packed enum payload failed: $status $output $error';
			} catch (error:Dynamic) {
				if (sys.FileSystem.exists(path)) sys.FileSystem.deleteFile(path);
				for (capture in captures) if (sys.FileSystem.exists(capture)) sys.FileSystem.deleteFile(capture);
				throw error;
			}
			sys.FileSystem.deleteFile(path);
			if (target == HashLink) for (capture in captures) {
				var census:Dynamic = haxe.Json.parse(sys.io.File.getContent(capture));
				sys.FileSystem.deleteFile(capture);
				if (census.allocations != 0) throw "Float32 payload boxes: " + census.allocations;
			}
			Sys.println('$target words=$bits inline=$inlineEnabled: Float32 crossings and zero allocations at 8/1024 calls');
		}
	}
}
