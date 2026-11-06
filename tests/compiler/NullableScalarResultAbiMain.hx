import compiler.ir.Ir;
import compiler.ir.IrBuilder;
import compiler.ir.IrFunction;
import compiler.backend.Backend.BackendTarget;
/** Nullable argument expansion must preserve the scalar ABI used for value results. */
class NullableScalarResultAbiMain {
	static function main():Void {
		for (inlineEnabled in [false, true]) for (target in [HashLink, Wasm32, WasmGc])
			for (managed in [false, true]) check(target, inlineEnabled, managed);
	}
	static function check(target:BackendTarget, inlineEnabled:Bool, managed:Bool):Void {
		var source = managed
			? 'class Owner { public function new() {} } '
				+ 'class Census { public static var owner:Owner; @:expose public static function prepare():Void owner=new Owner(); } '
				+ 'struct Pair { public final a:Int; public final b:Int; public final owner:Owner; '
				+ 'public function new(a:Int,b:Int,owner:Owner) { this.a=a; this.b=b; this.owner=owner; } } '
				+ 'function make(v:Null<Int>,o:Owner):Pair { var x=v==null?0:v; return new Pair(x,2,o); } '
				+ 'function forward(v:Null<Int>,o:Owner):Pair return make(v,o); '
				+ 'function main():Int { if(Census.owner==null) return 1; var a=forward(40,Census.owner); var b=forward(null,Census.owner); '
				+ 'if(a.owner!=Census.owner || b.owner!=Census.owner) return 1; return a.a+a.b+b.a==42?42:1; }'
			: 'struct Pair { public final a:Int; public final b:Int; public function new(a:Int,b:Int) { this.a=a; this.b=b; } } '
				+ 'function make(v:Null<Int>):Pair { var x=v==null?0:v; return new Pair(x,2); } '
				+ 'function forward(v:Null<Int>):Pair return make(v); '
				+ 'function main():Int { var a=forward(40); var b=forward(null); return a.a+a.b+b.a==42?42:1; }';
		var p = compiler.Frontend.compile(source), interpreter = new compiler.ir.IrInterpreter(p);
		if (managed) interpreter.run("Census.prepare");
		if (interpreter.run("main") != 42) throw "Nullable source result";
		compiler.ir.IrValueConstructors.rewrite(p);
		compiler.ir.IrValuePhiScalarization.rewrite(p);
		compiler.ir.IrScalarArguments.rewrite(p, target != HashLink);
		var objects = compiler.ir.IrObjectTable.of([for (object in p.objects) object.name => object]);
		p.functions = [for (fn in p.functions) compiler.ir.IrScalarReplacement.rewrite(fn, objects, false, target == HashLink)];
		compiler.ir.IrNullableScalarFlow.rewrite(p);
		compiler.ir.IrVerifier.verify(p);
		compiler.ir.IrInliner.run(p, new compiler.ir.IrInliner.IrInlineCache(), inlineEnabled);
		compiler.ir.IrVerifier.verify(p);
		var root = Sys.getEnv("TMPDIR");
		if (root == null) root = "/tmp";
		var stem = root + "/nullable-scalar-result-" + Std.random(0x7fffffff);
		var b = new IrBuilder(), captures:Array<String> = [];
		if (managed) b.call("Census.prepare", [], Void);
		var result = b.call("main", [], I32);
		if (target == HashLink) {
			p.natives.push({name:"start",library:"std",symbol:"gc_census_start",arguments:[I32],result:Void});
			p.natives.push({name:"stop",library:"std",symbol:"gc_census_stop",arguments:[],result:Void});
			p.natives.push({name:"reset",library:"std",symbol:"gc_census_reset",arguments:[],result:Void});
			p.natives.push({name:"dump",library:"haxeon_runtime",symbol:"__gc_census_dump",arguments:[Bytes],result:Void});
			for (n in [8, 1024]) {
				var path = stem + "-" + n + ".json";
				captures.push(path);
				b.call("reset", [], Void);
				b.call("start", [b.constInt(0)], Void);
				for (_ in 0...n) b.call("main", [], I32);
				b.call("stop", [], Void);
				b.call("dump", [b.constString(path)], Void);
			}
		}
		b.call("__exit", [result], Void);
		b.returnValue(b.constVoid());
		p.functions.push(new IrFunction("entry", b.arguments, Void, b.blocks));
		p.entryPoint = target == HashLink ? "entry" : "main";
		var bytes = target == HashLink
			? new compiler.backend.hl.HlBackend().compile(p, {target: target, debugNames: true}).bytes
			: new compiler.backend.wasm.WasmBackend().compile(p, {target: target, debugNames: true,
				wasmGcAllocationCount: target == WasmGc, wasmMemoryStats: target == Wasm32}).bytes;
		var path = stem + (target == HashLink ? ".hl" : ".wasm");
		try {
			sys.io.File.saveBytes(path, bytes);
			var js = 'const fs=require("fs"),e=new WebAssembly.Instance(new WebAssembly.Module(fs.readFileSync(process.argv[1]))).exports,'
				+ 'c=e.__allocation_count||e["haxeon.memory.allocation_count"];'
				+ (managed ? 'if(typeof e["Census.prepare"]!=="function")throw Error("missing managed setup export");e["Census.prepare"]();' : "")
				+ 'if(e.main()!==42)throw Error("warm result");'
				+ 'for(const n of [8,1024]){const b=c();for(let i=0;i<n;i++)if(e.main()!==42)throw Error("result");'
				+ 'if(c()!==b)throw Error("nullable/value ABI allocated "+(c()-b));}';
			var vm = Sys.getEnv("HAXEON_HASHLINK_DIR"), command = target == HashLink ? (vm == null ? "scripts/hl" : vm + "/hl") : "node";
			var child = new sys.io.Process(command, target == HashLink ? [path] : ["-e", js, path]);
			var error = child.stderr.readAll().toString(), code = child.exitCode();
			child.close();
			if (code != (target == HashLink ? 42 : 0)) throw '$target inline=$inlineEnabled managed=$managed: $code $error';
			for (capture in captures) {
				var data:Dynamic = haxe.Json.parse(sys.io.File.getContent(capture));
				if (data.allocations != 0) throw 'Nullable value-result calls allocated: ${haxe.Json.stringify(data)}';
			}
		} catch (error:Dynamic) {
			removeFiles([path].concat(captures));
			throw error;
		}
		removeFiles([path].concat(captures));
		Sys.println('PASS: $target inline=$inlineEnabled managed=$managed nullable arguments/value result; zero allocations at 8/1024 calls');
	}

	static function removeFiles(paths:Array<String>):Void {
		for (path in paths) if (sys.FileSystem.exists(path)) sys.FileSystem.deleteFile(path);
	}
}
