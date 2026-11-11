import compiler.Compiler;
import compiler.backend.Backend.BackendTarget;
import compiler.ir.Ir;

/** One paired release program: fields, scalar calls, closures and arrays have no tag representation cost. */
class EnumTagReleaseSizeMain {
	static function main():Void {
		for (target in ["hl", "wasm32", "wasm-gc"])
			for (inlining in [false, true]) {
				var integer = compile(target, inlining, false),
					nominal = compile(target, inlining, true);
				if (nominal.length > integer.length)
					throw target + " tag representation overhead: " + nominal.length + " > " + integer.length;
				run(target, integer);
				run(target, nominal);
				Sys.println("SIZE " + target + " inline=" + inlining + " Int=" + integer.length + " enum=" + nominal.length);
				checkReflection(target, inlining);
			}
	}

	static function newSession(target:String, inlining:Bool):Compiler {
		var session = new Compiler(null, compiler.runtime.CompilerIntrinsics.configuration());
		session.addStandardLibrarySourceRoot("stdlib");
		session.configure("tag-release-size", "tag-release-size",
			compiler.tools.CompilerDriver.targetDefines(target).concat(["haxeon-inline=" + (inlining ? 1 : 0)]));
		session.livePatching = false;
		session.developmentMetadata = false;
		return session;
	}

	static function compile(target:String, inlining:Bool, nominal:Bool):haxe.io.Bytes {
		var session = newSession(target, inlining);
		session.update("Main.hx",
			(nominal ? 'enum Mode implements Equatable { Off; On; Hot; }' : 'enum abstract Mode(Int) { var Off=1; var On=2; var Hot=3; }')
			+ '\nclass Holder { public var mode:Mode; public function new(mode:Mode) this.mode=mode; }'
			+ '\nfunction same(a:Mode,b:Mode):Bool return a==b;'
			+ '\nfunction main():Int { var h=new Holder(On), a:Array<Mode>=[Off,On,Hot], f:Mode->Mode=function(v:Mode):Mode return v; '
			+ 'a[0]=h.mode; return same(a[0],f(On)) && a[2]==Hot ? 42 : 1; }');
		var program = session.compile("Main").ir;
		if (nominal && compiler.ir.IrEnumRuntimeTypes.declarations(program).length != 0)
			throw "Unobserved tag retained a boxed descriptor";
		return encode(program, target);
	}

	static function checkReflection(target:String, inlining:Bool):Void {
		var session = newSession(target, inlining);
		session.update("Main.hx",
			'enum Mode implements Equatable { Off; On; Hot; }'
			+ '\nclass Inner { public var mode:Mode; public function new() mode=On; }'
			+ '\nclass Outer { public var inner:Inner; public function new() inner=new Inner(); }'
			+ '\nfunction main():Int { var owner=new Outer(), d:Dynamic=owner, inner=Reflect.field(d,"inner");'
			+ '\nif(Reflect.fields(d).length!=1 || Reflect.fields(inner).length!=1 || Reflect.field(inner,"mode")!=On) return 1;'
			+ '\nReflect.setField(inner,"mode",Hot); if(owner.inner.mode!=Hot) return 2;'
			+ '\nvar values:Array<Mode>=[Off,On], erased:Dynamic=values, view:Array<Dynamic>=cast erased;'
			+ '\nvar recovered:Mode=cast view[1]; if(Type.enumIndex(recovered)!=1) return 3; view[0]=Hot; return values[0]==Hot ? 42 : 4; }');
		var program = session.compile("Main").ir;
		if (!Lambda.exists(compiler.ir.IrEnumRuntimeTypes.declarations(program), entry -> entry.name == "Mode"))
			throw "Transitive reflection lost its boxed enum descriptor";
		run(target, encode(program, target));
		Sys.println("PASS: release tag reflection " + target + " inline=" + inlining);
	}

	static function encode(program:IrProgram, target:String):haxe.io.Bytes
		return target == "hl" ? new compiler.backend.hl.HlBackend().compile(program, {target: HashLink, developmentMetadata: false, debugNames: true})
			.bytes : new compiler.backend.wasm.WasmBackend().compile(program,
				{target: target == "wasm32" ? Wasm32 : WasmGc, developmentMetadata: false, debugNames: true})
				.bytes;

	static function run(target:String, bytes:haxe.io.Bytes):Void {
		var temp = Sys.getEnv("TMPDIR");
		if (temp == null)
			temp = "out";
		var path = temp + "/tag-release-size-" + Std.random(0x7fffffff) + (target == "hl" ? ".hl" : ".wasm");
		sys.io.File.saveBytes(path, bytes);
		try {
			var script = 'const e=new WebAssembly.Instance(new WebAssembly.Module(require("fs").readFileSync(process.argv[1]))).exports;'
				+ 'if(e.main()!==42)throw Error("release enum tag semantics");';
			var child = new sys.io.Process(target == "hl" ? "scripts/hl" : "node", target == "hl" ? [path] : ["-e", script, path]);
			var output = child.stdout.readAll().toString(),
				error = child.stderr.readAll().toString(),
				status = child.exitCode();
			child.close();
			if (status != (target == "hl" ? 42 : 0))
				throw target + ": " + status + " " + output + error;
		} catch (error:Dynamic) {
			sys.FileSystem.deleteFile(path);
			throw error;
		}
		sys.FileSystem.deleteFile(path);
	}
}
