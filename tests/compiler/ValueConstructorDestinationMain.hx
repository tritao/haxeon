import compiler.Compiler;
import compiler.tools.CompilerDriver;
import compiler.backend.wasm.WasmBackend;
import compiler.hl.HlWriter;
import runtime.Runtime;
import sys.FileSystem;
import sys.io.File;

class ValueConstructorDestinationMain {
	static function main():Void {
		var root = Sys.getEnv('TMPDIR');
		if (root == null || root == '')
			root = '/tmp';
		var temp = new sys.io.Process('mktemp', ['-d', root + '/value-constructor-destination.XXXXXX']);
		var dir = StringTools.trim(temp.stdout.readAll().toString()),
			status = temp.exitCode();
		temp.close();
		if (status != 0 || dir == '')
			throw 'could not create value constructor temporary directory';
		var prior = Sys.getEnv('VALUE_CONSTRUCTOR_CENSUS');
		try {
			var source = File.getContent('tests/programs/value-constructor-destination.hx');
			for (target in ['hl', 'wasm32', 'wasm-gc'])
				for (inlining in [false, true])
					check(source, dir, target, inlining);
		} catch (error:Dynamic) {
			cleanup(dir);
			Sys.putEnv('VALUE_CONSTRUCTOR_CENSUS', prior);
			throw error;
		}
		cleanup(dir);
		Sys.putEnv('VALUE_CONSTRUCTOR_CENSUS', prior);
		Sys.println('PASS: value constructor destinations on all targets');
	}

	static function cleanup(dir:String):Void {
		if (FileSystem.exists(dir)) {
			for (name in FileSystem.readDirectory(dir))
				FileSystem.deleteFile(dir + '/' + name);
			FileSystem.deleteDirectory(dir);
		}
	}

	static function check(source:String, dir:String, target:String, inlining:Bool):Void {
		var c = new Compiler(null, compiler.runtime.CompilerIntrinsics.configuration());
		c.addStandardLibrarySourceRoot('stdlib');
		c.setExportedFunctions(['ValueConstructorDestination.prepare', 'ValueConstructorDestination.perform']);
		c.configure('value-destination-' + target + '-' + inlining, 'value-destination',
			CompilerDriver.targetDefines(target).concat(['haxeon-inline=' + (inlining ? 1 : 0)]));
		c.update('ValueConstructorDestination.hx', source);
		var result = c.compile('ValueConstructorDestination');
		if (target == 'hl') {
			var census = dir + '/census-' + inlining + '.json';
			Sys.putEnv('VALUE_CONSTRUCTOR_CENSUS', census);
			var live = Runtime.load(HlWriter.encode(result.module).flatten(), result.runtimeIdentity);
			var id = result.functionIds.get('ValueConstructorDestination.main');
			var status = Runtime.callInt(live, id);
			Runtime.dispose(live);
			if (status != 42)
				throw 'HL constructor test returned ' + status;
			var data:Dynamic = haxe.Json.parse(File.getContent(census));
			if (data.allocations != 0)
				throw 'HL constructor test allocated ' + data.allocations;
			FileSystem.deleteFile(census);
		} else {
			var path = dir + '/' + target + '-' + inlining + '.wasm';
			File.saveBytes(path, new WasmBackend().compile(result.ir, {
				target: target == 'wasm32' ? Wasm32 : WasmGc,
				debugNames: true,
				wasmMemoryStats: target == 'wasm32',
				wasmGcAllocationCount: target == 'wasm-gc',
				exports: ['ValueConstructorDestination.prepare', 'ValueConstructorDestination.perform']
			}).bytes);
			var js = 'const fs=require("fs");const m=new WebAssembly.Module(fs.readFileSync(process.argv[1]));const r={__math_is_finite:Number.isFinite,__math_ceil:Math.ceil,__math_floor:Math.floor,__math_round:x=>Math.floor(x+.5)|0,__math_pow:Math.pow,__math_sqrt:Math.sqrt,__math_fmod:(a,b)=>a%b,__math_sin:Math.sin,__math_cos:Math.cos,__math_tan:Math.tan,__math_atan2:Math.atan2,__math_exp:Math.exp,__math_log:Math.log,__std_int_f64:Math.trunc};class Exit{constructor(code){this.code=code}}const e=new WebAssembly.Instance(m,{haxeon_runtime:r,std:{sys_exit:c=>{throw new Exit(c)}},haxeon_host:{}}).exports;let status;try{status=e.main()}catch(x){if(!(x instanceof Exit))throw x;status=x.code}if(status!==42)throw Error("main="+status);const count=e.__allocation_count||e["haxeon.memory.allocation_count"];e["ValueConstructorDestination.prepare"](8);if(e["ValueConstructorDestination.perform"](8)!==48)throw Error("warmup");e["ValueConstructorDestination.prepare"](1024);const before=count(),sum=e["ValueConstructorDestination.perform"](1024),allocated=count()-before;if(sum!==6144||allocated!==0)throw Error("sum="+sum+", allocations="+allocated);';
			if (Sys.command('node', ['-e', js, path]) != 0)
				throw target + ' constructor test failed';
			FileSystem.deleteFile(path);
		}
	}
}
