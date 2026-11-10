import compiler.Compiler;
import compiler.Compiler.CompileResult;
import compiler.backend.wasm.WasmBackend;
import compiler.hl.HlWriter;
import compiler.ir.IrFunction.IrRetention;
import compiler.runtime.CompilerIntrinsics;
import compiler.tools.CompilerDriver;
import compiler.tools.CompilerArguments;
import compiler.tools.CompilerSession;

class HostExportRootsMain {
	static function retention(result:CompileResult, name:String):IrRetention {
		for (fn in result.ir.functions) if (fn.name == name) return fn.retention;
		throw 'Missing host function "$name"';
	}
	static function main():Void {
		var source = sys.io.File.getContent("tests/programs/host-enum-export.hx");
		var session = new CompilerSession(), options = ["--target=wasm-gc", "--entry=host-enum-export", "--root=tests/programs",
			"--root=stdlib", "tests/programs/host-enum-export.hx"], entry = "host-enum-export";
		var ordinary = session.prepare(CompilerArguments.parse(options), _ -> {});
		var ordinaryBuild = ordinary.compile(entry);
		if (retention(ordinaryBuild, "HostEnumExports.cached") != Reachable) throw "Unexpected CLI export";
		ordinary.acknowledgePublication(ordinaryBuild.revision);
		var request = CompilerArguments.parse(options.concat(["--export=HostEnumExports.cached"]));
		var declared = session.prepare(request, _ -> {});
		var declaredBuild = declared.compile(entry);
		if (declared == ordinary || retention(declaredBuild, "HostEnumExports.cached") != Expose)
			throw "CLI export roots were omitted from session configuration";
		declared.acknowledgePublication(declaredBuild.revision);
		if (session.prepare(request, _ -> {}) != declared || !declared.compile(entry).unchanged)
			throw "Unchanged CLI export roots did not reuse the session";
		for (inlineEnabled in [false, true]) for (target in ["hl", "wasm32", "wasm-gc"]) {
			var compiler = new Compiler(null, CompilerIntrinsics.configuration());
			compiler.addStandardLibrarySourceRoot("stdlib");
			compiler.configure("host-roots-" + target + inlineEnabled, "host-roots",
				CompilerDriver.targetDefines(target).concat(["haxeon-inline=" + (inlineEnabled ? 1 : 0)]));
			compiler.update("Main.hx", source);
			var cold = compiler.compile("Main");
			if (retention(cold, "HostEnumExports.cached") != Reachable) throw "Unrequested function exposed";
			var requested = ["HostEnumExports.cached", "HostEnumExports.cached"];
			compiler.setExportedFunctions(requested);
			requested.push("not-a-root");
			var exposed = compiler.compile("Main");
			if (retention(exposed, "HostEnumExports.cached") != Expose) throw "Export root reached the frontend too late";
			if (retention(cold, "HostEnumExports.cached") != Reachable) throw "Export selection mutated cached source IR";
			compiler.setExportedFunctions(["HostEnumExports.cached"]);
			if (!compiler.compile("Main").unchanged) throw "Equivalent export roots invalidated the compile";
			var temp = Sys.getEnv("TMPDIR");
			if (temp == null) temp = "out";
			var path = temp + "/host-enum-export-" + target + "-" + inlineEnabled + (target == "hl" ? ".hl" : ".wasm");
			var bytes = target == "hl" ? HlWriter.encode(exposed.module).flatten() : new WasmBackend().compile(exposed.ir,
				{target: target == "wasm32" ? Wasm32 : WasmGc, debugNames: true,
					wasmMemoryStats: target == "wasm32", wasmGcAllocationCount: target == "wasm-gc"}).bytes;
			sys.io.File.saveBytes(path, bytes);
			var js = 'const e=new WebAssembly.Instance(new WebAssembly.Module(require("fs").readFileSync(process.argv[1])),{}).exports;'
				+ 'if(e.main()!==42)throw Error("main");const cached=e["HostEnumExports.cached"],perform=e["HostEnumExports.perform"],count=e.__allocation_count||e["haxeon.memory.allocation_count"];'
				+ 'if(typeof cached!=="function")throw Error("missing declared host root");const first=cached();'
				+ 'for(const n of [8,1024]){const before=count();for(let i=0;i<n;i++)if(cached()!==first)throw Error("cached enum changed");'
				+ 'if(perform(n)!==42*n||count()!==before)throw Error("host enum result allocated");}';
			var status = Sys.command(target == "hl" ? "scripts/hl" : "node", target == "hl" ? [path] : ["-e", js, path]);
			sys.FileSystem.deleteFile(path);
			if (status != (target == "hl" ? 42 : 0)) throw 'Host root failed: $target inline=$inlineEnabled';
			compiler.setExportedFunctions([]);
			var removed = compiler.compile("Main");
			if (retention(removed, "HostEnumExports.cached") != Reachable || retention(removed, "HostEnumExports.perform") != Expose)
				throw "Removing a requested root lost the source retention policy";
		}
		Sys.println("PASS: host roots precede layout selection, preserve source IR and return cached enums without allocations on all targets");
	}
}
