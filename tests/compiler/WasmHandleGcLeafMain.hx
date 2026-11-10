import compiler.backend.wasm.WasmBackend;
import compiler.ir.Ir;
import compiler.ir.IrBuilder;
import compiler.ir.IrFunction;
import compiler.ir.SourceProvenance;
import compiler.ir.SourceProvenance.Located;
import sys.io.File;

/** Numeric handles held in Dynamic must not retain an object whose address equals the handle. */
class WasmHandleGcLeafMain {
	static function main():Void {
		var provenance = SourceProvenance.generated("handle-gc-leaf"), program = new IrProgram("main");
		program.objects = [
			{name: "Victim", isValue: false, base: null, interfaces: [], fields: [{name: "number", type: I32}], methods: []},
			{name: "Garbage", isValue: false, base: null, interfaces: [],
				fields: [for (index in 0...8) {name: 'field$index', type: I32}], methods: []}
		];
		program.staticFields = [{name: "victim", type: Obj("Victim")}, {name: "handle", type: Dyn}, {name: "garbage", type: Obj("Garbage")}];
		var main = new IrBuilder(); main.returnValue(main.constInt(42));
		var make = new IrBuilder(), victim = make.newObject("Victim");
		make.currentBlock().instructions.push(new Located(GlobalSet("victim", victim), provenance));
		make.returnValue(victim);
		program.functions = [new IrFunction("main", [], I32, main.blocks, None), new IrFunction("make", [], Obj("Victim"), make.blocks, None)];
		for (entry in [{name: "holdType", type: TypeRef}, {name: "holdCallback", type: Abstract("native_callback")}]) {
			var hold = new IrBuilder(), handle = hold.argument("handle", entry.type), boxed = hold.toDyn(handle);
			hold.currentBlock().instructions.push(new Located(GlobalSet("handle", boxed), provenance));
			var none = hold.constNull(Obj("Victim"));
			hold.currentBlock().instructions.push(new Located(GlobalSet("victim", none), provenance));
			hold.returnValue(hold.constVoid());
			program.functions.push(new IrFunction(entry.name, hold.arguments, Void, hold.blocks, None));
		}
		var collect = new IrBuilder(), garbage = collect.newObject("Garbage");
		collect.currentBlock().instructions.push(new Located(GlobalSet("garbage", garbage), provenance));
		collect.returnValue(collect.constVoid());
		program.functions.push(new IrFunction("collect", [], Void, collect.blocks, None));
		var wasm = new WasmBackend().compile(program, {target: Wasm32, debugNames: true, wasmGcStress: true,
			exports: ["make", "holdType", "holdCallback", "collect"]}).bytes,
			directory = Sys.getEnv("TMPDIR");
		if (directory == null || directory == "") directory = Sys.getCwd() + "/out/test-tools";
		if (!sys.FileSystem.exists(directory)) sys.FileSystem.createDirectory(directory);
		var path = '$directory/haxeon-handle-leaf-${Std.random(0x7fffffff)}.wasm';
		File.saveBytes(path, wasm);
		var script = 'const fs=require("fs"), m=new WebAssembly.Module(fs.readFileSync(process.argv[1])); '
			+ 'for(const hold of ["holdType","holdCallback"]) { const e=new WebAssembly.Instance(m).exports, victim=e.make(); '
			+ 'e[hold](victim); const before=new DataView(e.memory.buffer).getInt32(victim-12,true); e.collect(); '
			+ 'const after=new DataView(e.memory.buffer).getInt32(victim-12,true); '
			+ 'if(!(before&1) || (after&1)) throw Error(hold+" retained the victim: "+before+" / "+after); }';
		var process = new sys.io.Process("node", ["-e", script, path]), error = process.stderr.readAll().toString(), status = process.exitCode();
		process.close(); sys.FileSystem.deleteFile(path);
		if (status != 0) throw 'Wasm32 numeric handle GC leaf failed: $error';
		Sys.println("PASS: erased callback and type handles are GC leaves");
	}
}
