import compiler.Compiler;
import compiler.Diagnostic.CompileError;

class InterfaceOptionalArgumentsMain {
	static final declaration = "interface Service { public function value(required:Int, ?suffix:String):Int; }";
	static final implementation = "class Impl implements Service { public function new() {} public function value(required:Int, ?suffix:String):Int return required + (suffix == null ? 2 : suffix.length); }";
	static final valid = "function main():Int { var service:Service = new Impl(); return service.value(40); }";

	static function compiler():Compiler {
		var result = new Compiler();
		result.update("Service.hx", declaration);
		result.update("Impl.hx", implementation);
		return result;
	}

	static function accept(result:Compiler):Void {
		result.update("Main.hx", valid);
		if (GeneratedProgramRunner.exitCode(result.compile("Main")) != 42)
			throw "optional interface argument execution failed";
	}

	static function reject(result:Compiler, source:String, code:String):Void {
		result.update("Main.hx", source);
		var rejected = false;
		try
			result.compile("Main")
		catch (error:CompileError) {
			if (error.diagnostic.code != code)
				throw error;
			rejected = true;
		}
		if (!rejected)
			throw "invalid optional interface call was accepted";
	}

	static function main():Void {
		var result = compiler();
		accept(result);
		for (candidate in [result, compiler()]) {
			reject(candidate, StringTools.replace(valid, "value(40)", "value()"), "E1008");
			reject(candidate, StringTools.replace(valid, "value(40)", "value(40, 7)"), "E1009");
			reject(candidate, StringTools.replace(valid, "value(40)", "value(40, null, 1)"), "E1008");
		}
		result.update("Service.hx", StringTools.replace(declaration, "?suffix", "suffix"));
		reject(result, valid, "E1008");
		result.update("Service.hx", declaration);
		accept(result);
		Sys.println("PASS: optional interface calls preserve metadata, runtime and cold/incremental rejection");
	}
}
