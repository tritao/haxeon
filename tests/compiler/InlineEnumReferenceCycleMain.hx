import compiler.Frontend;
import compiler.backend.Backend.BackendTarget;
import compiler.ir.Ir;
import compiler.ir.IrBuilder;
import compiler.ir.IrFunction;
import compiler.ir.IrInlineEnumCaseAccess;
import compiler.ir.IrInlineEnumLayout;
import compiler.ir.IrObjectTable;
import compiler.ir.IrVerifier;

/** Reference cycles have finite inline size; their payloads remain traced through a carrier's only root. */
@:access(compiler.ir.IrBuilder)
class InlineEnumReferenceCycleMain {
	static final source = '
enum Links {
	Leaf(code:Int);
	Children(values:Array<Links>);
	Action(callback:Links->Int);
	Entries(values:Map<Int,Links>);
}
enum Direct { Again(next:Null<Direct>); }
function makeArray(code:Int):Array<Links> return [Leaf(code)];
function makeAction(code:Int):Links->Int {
	var held:Links = Leaf(code);
	return ignored -> switch held { case Leaf(value): value; default: 0; };
}
function makeMap(code:Int):Map<Int,Links> {
	var values = new Map<Int,Links>();
	values.set(0, Leaf(code));
	return values;
}
function readArray(values:Array<Links>):Int return switch values[0] { case Leaf(code): code; default: 0; };
function readAction(callback:Links->Int):Int return callback(null);
function readMap(values:Map<Int,Links>):Int return switch values.get(0) { case Leaf(code): code; default: 0; };
function main():Int return 42;
';

	static function main():Void {
		for (target in [HashLink, Wasm32, WasmGc])
			for (inlineEnabled in [false, true]) check(target, inlineEnabled);
		Sys.println("PASS: reference-cycle enum carriers are inline, allocation-free and GC-rooted on all targets");
	}

	static function check(target:BackendTarget, inlineEnabled:Bool):Void {
		var program = Frontend.compile(source);
		var laneTarget:compiler.ir.IrValueLaneLayout.IrValueLaneTarget = target == HashLink ? HashLink : target == Wasm32 ? Wasm32 : WasmGc;
		var planner = new IrInlineEnumLayout(program.enums, program.objects, target == HashLink ? 64 : 32, laneTarget);
		var shape = planner.shape("Links");
		if (shape == null || shape.references != 1 || shape.scalarWords != 1 || planner.shape("Direct") != null)
			throw "Reference edges must break cycles; direct nullable value containment must remain boxed";
		for (declaration in program.enums)
			if (declaration.name == "Links" && declaration.isRecursive == true
				|| declaration.name == "Direct" && declaration.isRecursive != true)
				throw "Semantic classification disagrees with the inline layout";
		program.objects = program.objects.concat(planner.generatedObjects());
		var access = new IrInlineEnumCaseAccess(shape, IrObjectTable.of([for (object in program.objects) object.name => object]));
		var factories = ["makeArray", "makeAction", "makeMap"], readers = ["readArray", "readAction", "readMap"];
		var prepare = new IrBuilder(), churn = new IrBuilder(), probe = new IrBuilder();
		var bad = probe.createBlock();
		for (index in 0...factories.length) {
			var constructor = index + 1, root = "$reference-cycle:" + index, type = shape.cases[constructor].parameters[0];
			program.staticFields.push({name: root, type: Obj(shape.valueObject.name)});
			var payload = prepare.call(factories[index], [prepare.constInt(42)], type);
			prepare.emit(GlobalSet(root, access.construct(prepare, constructor, [payload])));
			churn.call(factories[index], [churn.constInt(-1)], type);
			var saved = probe.temporary(Obj(shape.valueObject.name));
			probe.emit(GlobalGet(saved, root));
			// Copy a case through its actual inline storage, rather than testing only the reference intrinsic.
			var copied = access.construct(probe, constructor, [access.field(probe, saved, constructor, 0)]);
			var restored = access.field(probe, copied, constructor, 0);
			var result = probe.call(readers[index], [restored], I32), next = probe.createBlock();
			probe.branch(probe.equal(result, probe.constInt(42)), next, bad);
			probe.select(next);
		}
		prepare.returnValue(prepare.constVoid());
		churn.returnValue(churn.constVoid());
		probe.returnValue(probe.constInt(42));
		probe.select(bad); probe.returnValue(probe.constInt(1));
		program.functions.push(new IrFunction("prepareRoots", prepare.arguments, Void, prepare.blocks, Ordinary, null, false, Expose));
		program.functions.push(new IrFunction("churnRoots", churn.arguments, Void, churn.blocks, Ordinary, null, false, Expose));
		program.functions.push(new IrFunction("probeRoots", probe.arguments, I32, probe.blocks, Ordinary));
		var table = IrObjectTable.of([for (object in program.objects) object.name => object]);
		program.functions = [for (fn in program.functions) compiler.ir.IrScalarReplacement.rewrite(fn, table, false, target == HashLink)];
		compiler.ir.IrInliner.run(program, new compiler.ir.IrInliner.IrInlineCache(), compiler.ir.TargetProfile.wasm, inlineEnabled);
		IrVerifier.verify(program);
		var temp = Sys.getEnv("TMPDIR"), directory = temp == null ? "/tmp" : temp;
		var stem = directory + "/reference-cycle-" + Std.random(0x7fffffff) + "-" + Std.string(target);
		var captures:Array<{path:String, count:Int}> = [];
		if (target == HashLink) {
			var natives:Array<IrNative> = [
				{name:"major", library:"std", symbol:"gc_major", arguments:[], result:Void},
				{name:"start", library:"std", symbol:"gc_census_start", arguments:[I32], result:Void},
				{name:"stop", library:"std", symbol:"gc_census_stop", arguments:[], result:Void},
				{name:"reset", library:"std", symbol:"gc_census_reset", arguments:[], result:Void},
				{name:"dump", library:"haxeon_runtime", symbol:"__gc_census_dump", arguments:[Bytes], result:Void},
				{name:"exit", library:"std", symbol:"sys_exit", arguments:[I32], result:Void}
			];
			for (native in natives) program.natives.push(native);
			var entry = new IrBuilder(); entry.call("prepareRoots", [], Void); entry.call("major", [], Void);
			for (_ in 0...128) entry.call("churnRoots", [], Void);
			entry.call("major", [], Void);
			var result = entry.call("probeRoots", [], I32);
			for (count in [8, 1024]) {
				var path = stem + "-" + count + ".json"; captures.push({path:path, count:count});
				entry.call("reset", [], Void); entry.call("start", [entry.constInt(0)], Void);
				for (_ in 0...count) entry.call("probeRoots", [], I32);
				entry.call("stop", [], Void); entry.call("dump", [entry.constString(path)], Void);
			}
			entry.call("exit", [result], Void); entry.returnValue(entry.constVoid());
			program.functions.push(new IrFunction("entry", entry.arguments, Void, entry.blocks, Ordinary));
		}
		program.entryPoint = target == HashLink ? "entry" : "probeRoots";
		IrVerifier.verify(program);
		var bytes = target == HashLink
			? new compiler.backend.hl.HlBackend().compile(program, {target:target, debugNames:true}).bytes
			: new compiler.backend.wasm.WasmBackend().compile(program,
				{target:target, debugNames:true, wasmGcAllocationCount:target == WasmGc,
					wasmMemoryStats:target == Wasm32, wasmGcStress:target == Wasm32}).bytes;
		var path = stem + (target == HashLink ? ".hl" : ".wasm"); sys.io.File.saveBytes(path, bytes);
		try {
			var js = 'const fs=require("fs"),e=new WebAssembly.Instance(new WebAssembly.Module(fs.readFileSync(process.argv[1]))).exports;'
				+ 'e.prepareRoots();const collections=e["haxeon.memory.collection_count"],beforeGC=collections?collections():0;'
				+ 'global.gc();for(let i=0;i<128;i++)e.churnRoots();global.gc();'
				+ 'if(collections&&collections()<=beforeGC)throw Error("wasm32 guest did not collect");'
				+ 'if(e.main()!==42)throw Error("lost reference-cycle payload root");'
				+ 'const count=e.__allocation_count||e["haxeon.memory.allocation_count"];'
				+ 'for(const n of [8,1024]){const before=count();for(let i=0;i<n;i++)if(e.main()!==42)throw Error("payload");'
				+ 'if(count()!==before)throw Error("reference-cycle carrier allocated "+(count()-before)+" objects for "+n+" calls");}';
			var child = new sys.io.Process(target == HashLink ? "scripts/hl" : "node", target == HashLink ? [path] : ["--expose-gc", "-e", js, path]);
			var output = child.stdout.readAll().toString(), error = child.stderr.readAll().toString(), status = child.exitCode(); child.close();
			if (status != (target == HashLink ? 42 : 0)) throw Std.string(target) + ": " + status + " " + output + " " + error;
			for (capture in captures) {
				var census:Dynamic = haxe.Json.parse(sys.io.File.getContent(capture.path));
				if (census.allocations != 0) throw 'Reference-cycle carriers allocated ${census.allocations} objects for ${capture.count} calls';
			}
		} catch (error:Dynamic) {
			sys.FileSystem.deleteFile(path);
			for (capture in captures) if (sys.FileSystem.exists(capture.path)) sys.FileSystem.deleteFile(capture.path);
			throw error;
		}
		sys.FileSystem.deleteFile(path);
		for (capture in captures) sys.FileSystem.deleteFile(capture.path);
		Sys.println(Std.string(target) + " inline=" + inlineEnabled + ": rooted array/function/map payloads; zero objects for 8/1024 copies");
	}
}
