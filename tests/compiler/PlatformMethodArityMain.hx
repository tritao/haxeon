import compiler.Compiler;
import compiler.core.Diagnostic.CompileError;

/** A call of a method the platform implements (haxe.io.Bytes' `get`) with the wrong number of arguments is an E1008. */
class PlatformMethodArityMain {
	static function main():Void {
		var result = new Compiler();
		result.addStandardLibrarySourceRoot("stdlib");
		for (call in ["bytes.get(0, 1)", "bytes.get()"]) {
			result.update("Main.hx", 'function main():Int { var bytes = haxe.io.Bytes.alloc(4); return $call; }');
			var rejected = false;
			try
				result.compile("Main")
			catch (error:CompileError) {
				if (error.diagnostic.code != "E1008")
					throw error;
				rejected = true;
			}
			if (!rejected)
				throw '$call was accepted';
		}
	}
}
