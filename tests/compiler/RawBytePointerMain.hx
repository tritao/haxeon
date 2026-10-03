import compiler.Compiler;
import compiler.runtime.CompilerIntrinsics;
import compiler.Diagnostic.CompileError;

class RawBytePointerMain {
	static final source = 'import haxe.io.Bytes; @:hlNative("std") class Raw { '
		+ 'public static function ucs2length(pointer:hl.Bytes, offset:Int):Int return 0; } '
		+ 'function identity(pointer:hl.Bytes):hl.Bytes return pointer; '
		+ 'function main():Int { var bytes = Bytes.alloc(4); var pointer:hl.Bytes = bytes.getData(); '
		+ 'if (Raw.ucs2length(identity("é".bytes), 0) != 1) return 2; '
		+ 'return Raw.ucs2length(identity(bytes.getData()), 0) + Raw.ucs2length(pointer, 0); }';

	static function compiler():Compiler {
		var result = new Compiler(null, CompilerIntrinsics.configuration());
		result.addSourceRoot(Sys.getCwd() + "/stdlib");
		result.update("Main.hx", source);
		return result;
	}

	static function rejected(result:Compiler):Bool {
		try
			result.compile("Main")
		catch (error:CompileError) {
			if (error.diagnostic.code != "E1009")
				throw error;
			return true;
		}
		return false;
	}

	static function main():Void {
		var result = compiler();
		if (GeneratedProgramRunner.exitCode(result.compile("Main")) != 0)
			throw "raw byte pointer call failed";
		var invalid = StringTools.replace(source, "identity(bytes.getData())", "bytes");
		result.update("Main.hx", invalid);
		var cold = compiler();
		cold.update("Main.hx", invalid);
		if (!rejected(result) || !rejected(cold))
			throw "managed bytes accepted as a raw byte pointer";
		result.update("Main.hx", source);
		if (GeneratedProgramRunner.exitCode(result.compile("Main")) != 0)
			throw "restored raw pointer call failed";
		Sys.println("PASS: raw byte pointer identity, native execution and managed-byte rejection");
	}
}
