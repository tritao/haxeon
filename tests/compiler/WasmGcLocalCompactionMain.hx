import compiler.backend.wasm.WasmEncoder;
import compiler.backend.wasm.WasmModule.WasmFunction;
import compiler.backend.wasm.WasmModule.WasmLocal;
import compiler.backend.wasm.WasmModule.WasmModule;
import compiler.backend.wasm.WasmTypes.WasmInstruction;
import compiler.backend.wasm.WasmTypes.WasmValueType;
import compiler.backend.wasm.WasmTypes.WasmFunctionType;
import compiler.backend.wasm.gc.WasmGcLocalCompaction;

/** Compaction preserves live local values and does not discard trapping computations. */
class WasmGcLocalCompactionMain {
	static function main():Void {
		var locals:Array<WasmLocal> = [{type: I32}, {type: I32}, {type: I32}],
			body:Array<WasmInstruction> = [
				  I32Const(5), LocalSet(1), LocalGet(1), LocalGet(0), I32Add, LocalSet(3),
				I32Const(123), LocalSet(2), LocalGet(3), LocalGet(3), I32Add,      Return
			],
			trapBody:Array<WasmInstruction> = [I32Const(0), I32Const(0), I32DivS, LocalSet(2), I32Const(42), Return],
			compact = WasmGcLocalCompaction.run(body, locals, 1),
			compactTrap = WasmGcLocalCompaction.run(trapBody, locals, 0),
			module = new WasmModule("local-compaction");
		if (compact.locals.length != 1 || compactTrap.locals.length != 1)
			throw "Unused local slots were not removed";
		var mainType:WasmFunctionType = {parameters: [I32], results: [I32]},
			trapType:WasmFunctionType = {parameters: [], results: [I32]},
			pairType:WasmFunctionType = {parameters: [I32, I32], results: [I32]},
			exceptionBody:Array<WasmInstruction> = [
				I32Const(17), LocalSet(0), Try(null), I32Const(9), Throw(0),     Catch(0), LocalSet(1),
				 LocalGet(0), LocalGet(1),    I32Add,      Return,      End, I32Const(-1),      Return
			],
			pairBody:Array<WasmInstruction> = [
				  I32Const(4), LocalSet(2), LocalGet(2), LocalGet(0), I32Add, LocalSet(4),
				I32Const(100), LocalSet(3), LocalGet(4), LocalGet(1), I32Sub,      Return
			],
			referenceLocals:Array<WasmLocal> = [
				{
					type: Ref({nullable: true, heap: Any})
				},
				{type: I32}
			],
			referenceBody:Array<WasmInstruction> = [
				I32Const(9),
				LocalSet(1),
				RefNull(Any),
				LocalSet(0),
				LocalGet(0),
				RefIsNull,
				Return
			],
			exception = WasmGcLocalCompaction.run(exceptionBody, locals, 0),
			pair = WasmGcLocalCompaction.run(pairBody, locals, 2),
			reference = WasmGcLocalCompaction.run(referenceBody, referenceLocals, 0);
		module.addFunction(new WasmFunction("main", mainType, compact.locals, compact.body));
		module.addFunction(new WasmFunction("trap", trapType, compactTrap.locals, compactTrap.body));
		module.exceptionTagType = module.typeIndex({parameters: [I32], results: []});
		module.addFunction(new WasmFunction("exception", trapType, exception.locals, exception.body));
		module.addFunction(new WasmFunction("pair", pairType, pair.locals, pair.body));
		module.addFunction(new WasmFunction("reference", trapType, reference.locals, reference.body));
		module.exports.push({name: "main", functionIndex: 0});
		module.exports.push({name: "trap", functionIndex: 1});
		module.exports.push({name: "exception", functionIndex: 2});
		module.exports.push({name: "pair", functionIndex: 3});
		module.exports.push({name: "reference", functionIndex: 4});
		var root = Sys.getEnv("TMPDIR");
		if (root == null || root == "")
			throw "TMPDIR is required";
		var temp = new sys.io.Process("mktemp", ["-d", root + "/wasm-gc-locals.XXXXXX"]),
			dir = StringTools.trim(temp.stdout.readAll().toString()),
			status = temp.exitCode();
		temp.close();
		if (status != 0 || dir == "")
			throw "Cannot create Wasm local test directory";
		var path = dir + "/module.wasm";
		try {
			sys.io.File.saveBytes(path, WasmEncoder.encode(module));
			var js = 'let e=new WebAssembly.Instance(new WebAssembly.Module(require("fs").readFileSync(process.argv[1]))).exports;for(let x of [-7,0,4])if(e.main(x)!==(x+5)*2)throw Error("local value changed");if(e.exception()!==26||e.pair(20,3)!==21||e.reference()!==1)throw Error("local changed across exception, parameters or reference");let trapped=false;try{e.trap()}catch(e){if(e instanceof WebAssembly.RuntimeError)trapped=true;else throw e}if(!trapped)throw Error("trap removed")';
			if (Sys.command("node", ["-e", js, path]) != 0)
				throw "Compacted Wasm changed behavior";
		} catch (error:Dynamic) {
			if (sys.FileSystem.exists(path))
				sys.FileSystem.deleteFile(path);
			sys.FileSystem.deleteDirectory(dir);
			throw error;
		}
		sys.FileSystem.deleteFile(path);
		sys.FileSystem.deleteDirectory(dir);
		Sys.println("PASS: GC local compaction preserves values and traps");
	}
}
