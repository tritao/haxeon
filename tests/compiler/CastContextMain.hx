import compiler.Compiler;
import compiler.runtime.CompilerIntrinsics;
import compiler.Diagnostic.CompileError;

class CastContextMain {
	static final source = 'import haxe.io.Bytes; @:hlNative("haxeon_runtime") class Native { '
		+ 'public static function call_managed_bytes(module:hl.Abstract<"realtime_module">, index:Int):hl.Abstract<"realtime_bytes"> return null; } '
		+
		'class Host { static function invoke<T>(module:hl.Abstract<"realtime_module">, index:Int, shape:Int, operation:hl.Abstract<"realtime_module">->T):T return operation(module); '
		+
		'public static function convert(module:hl.Abstract<"realtime_module">, index:Int):Bytes return cast invoke(module, index, 7, function(handle) return Native.call_managed_bytes(handle, index)); '
		+
		'public static function roundTrip(bytes:Bytes):Bytes { var pointer:hl.Abstract<"realtime_bytes"> = cast bytes; return cast invoke(null, 0, 7, function(handle) return pointer); } } '
		+
		'function main():Int { var bytes = Host.roundTrip(Bytes.ofString("ok")); var rejected = false; try { var wrong:hl.Abstract<"wrong_bytes"> = cast bytes; } catch (error:Dynamic) rejected = true; if (!rejected) return 99; return bytes.length; }';

	static function main():Void {
		var result = new Compiler(null, CompilerIntrinsics.configuration());
		result.addSourceRoot(Sys.getCwd() + "/stdlib");
		result.update("Main.hx", source);
		if (GeneratedProgramRunner.exitCode(result.compile("Main")) != 2)
			throw "cast context fixture execution failed";
		var invalid = StringTools.replace(source, "return cast invoke", "return invoke");
		result.update("Main.hx", invalid);
		var rejected = false;
		try
			result.compile("Main")
		catch (error:CompileError) {
			if (error.diagnostic.code != "E1003")
				throw error;
			rejected = true;
		}
		if (!rejected)
			throw "opaque handle implicitly converted to managed bytes";
		var cold = new Compiler(null, CompilerIntrinsics.configuration());
		cold.addSourceRoot(Sys.getCwd() + "/stdlib");
		cold.update("Main.hx", invalid);
		rejected = false;
		try
			cold.compile("Main")
		catch (error:CompileError) {
			if (error.diagnostic.code != "E1003")
				throw error;
			rejected = true;
		}
		if (!rejected)
			throw "cold compile accepted an implicit opaque handle conversion";
		result.update("Main.hx", source);
		if (GeneratedProgramRunner.exitCode(result.compile("Main")) != 2)
			throw "restored cast fixture failed";
		Sys.println("PASS: explicit cast separates generic operand inference from destination");
	}
}
