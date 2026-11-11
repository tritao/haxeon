import compiler.ir.Ir;
import compiler.ir.IrFunction;

/** Presence, deletion and copying do not inspect a tag field's logical value. */
class ReflectionTagProjectionMain {
	static function main():Void {
		checkHelpers();
		for (target in ["hl", "wasm32", "wasm-gc"])
			for (inlining in [false, true])
				checkExecution(target, inlining);
	}

	static function checkHelpers():Void {
		var objects:Array<IrObject> = [
			{
				name: "Holder",
				isValue: false,
				base: null,
				interfaces: [],
				methods: [],
				fields: [{name: "mode", type: EnumTag("Mode")}]
			}
		];
		var natives:Array<IrNative> = [
			{
				name: "read",
				library: "haxeon_runtime",
				symbol: "__reflect_field",
				arguments: [Dyn, Bytes],
				result: Dyn
			},
			{
				name: "write",
				library: "haxeon_runtime",
				symbol: "__reflect_set_field",
				arguments: [Dyn, Bytes, Dyn],
				result: Void
			},
			{
				name: "has",
				library: "haxeon_runtime",
				symbol: "__reflect_has_field",
				arguments: [Dyn, Bytes],
				result: Bool
			},
			{
				name: "delete",
				library: "haxeon_runtime",
				symbol: "__reflect_delete_field",
				arguments: [Dyn, Bytes],
				result: Bool
			},
			{
				name: "count",
				library: "haxeon_runtime",
				symbol: "__reflect_field_count",
				arguments: [Dyn],
				result: I32
			},
			{
				name: "name",
				library: "haxeon_runtime",
				symbol: "__reflect_field_name",
				arguments: [Dyn, I32],
				result: Bytes
			},
			{
				name: "copy",
				library: "haxeon_runtime",
				symbol: "__reflect_copy",
				arguments: [Dyn],
				result: Dyn
			}
		];
		var functions:Array<IrFunction> = [],
			remaining = compiler.ir.ObjectReflection.generate(compiler.ir.ProgramFacts.empty(), natives, objects, ["Holder"], functions);
		var generated = [for (fn in functions) fn.name => true];
		for (name in ["read", "write", "count", "name", "has", "delete", "copy"])
			if (generated.exists(name) || !Lambda.exists(remaining, native -> native.name == name))
				throw "Unnecessary tag layout adapter: " + name;
		Sys.println("PASS: tag-only layouts share native checked field operations and listing");
	}

	static function checkExecution(target:String, inlining:Bool):Void {
		var session = new compiler.Compiler(null, compiler.runtime.CompilerIntrinsics.configuration());
		session.addStandardLibrarySourceRoot("stdlib");
		session.configure("reflection-tag-projection-" + target + inlining, "reflection-tag-projection",
			compiler.tools.CompilerDriver.targetDefines(target).concat(["haxeon-inline=" + (inlining ? 1 : 0)]));
		session.update("Main.hx",
			'enum Mode { First; Second; } '
			+
			'\nclass Holder { public var mode:Mode; public var number:Int; public var callback:Mode->Mode; public function new() {mode=Second;number=17;callback=function(value:Mode):Mode return value;} } '
			+ '\nfunction main():Int { var h=new Holder(), d:Dynamic=h; '
			+ '\nif (!Reflect.hasField(d,"mode") || Reflect.hasField(d,"absent") || Reflect.fields(d).length!=3) return 1; '
			+ '\nif (Reflect.field(d,"mode")!=Second) return 2; '
			+ '\nReflect.setField(d,"mode",First); if(h.mode!=First) return 3; '
			+ '\nvar c:Dynamic=Reflect.copy(d); Reflect.setField(d,"mode",Second); '
			+ '\nvar callback:Mode->Mode=Reflect.field(c,"callback"); if(callback(Second)!=Second) return 6; '
			+ '\nif(Reflect.field(c,"mode")!=First || Reflect.field(c,"number")!=17) return 4; '
			+
			'\nif(!Reflect.deleteField(d,"mode") || Reflect.deleteField(d,"absent") || Reflect.field(d,"mode")!=null || !Reflect.hasField(d,"mode")) return 5; '
			+ '\nreturn 42; }');
		var program = session.compile("Main").ir;
		var binary = target == "hl" ? new compiler.backend.hl.HlBackend().compile(program, {target: HashLink, debugNames: true})
			.bytes : new compiler.backend.wasm.WasmBackend().compile(program, {target: target == "wasm32" ? Wasm32 : WasmGc, debugNames: true}).bytes;
		var temp = Sys.getEnv("TMPDIR");
		if (temp == null)
			temp = "out";
		var path = temp
			+ "/reflection-tag-projection-"
			+ target
			+ inlining
			+ "-"
			+ Std.random(0x7fffffff)
			+ (target == "hl" ? ".hl" : ".wasm");
		sys.io.File.saveBytes(path, binary);
		try {
			var script = 'const e=new WebAssembly.Instance(new WebAssembly.Module(require("fs").readFileSync(process.argv[1]))).exports;'
				+ '\nif(e.main()!==42)throw Error("tag reflection");';
			var child = new sys.io.Process(target == "hl" ? "scripts/hl" : "node", target == "hl" ? [path] : ["-e", script, path]);
			var output = child.stdout.readAll().toString(),
				error = child.stderr.readAll().toString(),
				status = child.exitCode();
			child.close();
			if (status != (target == "hl" ? 42 : 0))
				throw target + " inline=" + inlining + ": " + output + error;
		} catch (error:Dynamic) {
			sys.FileSystem.deleteFile(path);
			throw error;
		}
		sys.FileSystem.deleteFile(path);
		Sys.println("PASS: tag reflection " + target + " inline=" + inlining);
	}
}
