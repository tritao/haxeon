import compiler.Compiler;
import compiler.Diagnostic.CompileError;

class FieldAssignmentContextMain {
	static final declarations = 'class FaceRange { public function new() {} } '
		+ 'class Part { public var faceRanges:Array<FaceRange>; public function new() { faceRanges = [new FaceRange()]; } } '
		+ 'class Data { public static var staticRanges:Array<FaceRange> = [new FaceRange()]; '
		+ 'public var parts:Array<Part>; public function new() { parts = [new Part()]; } } ';
	static final valid = 'function main():Int { var data = new Data(); data.parts[0].faceRanges = []; '
		+ 'Data.staticRanges = []; data.parts[0].faceRanges.push(new FaceRange()); Data.staticRanges.push(new FaceRange()); '
		+ 'return data.parts[0].faceRanges.length == 1 && Data.staticRanges.length == 1 ? 42 : 1; }';
	static final invalid = 'function main():Int { var data = new Data(); data.parts[0].faceRanges = []; '
		+ 'data.parts[0].faceRanges.push("wrong"); return 42; }';
	static final invalidStatic = 'function main():Int { Data.staticRanges = []; Data.staticRanges.push("wrong"); return 42; }';

	static function compiler(source:String):Compiler {
		var result = new Compiler();
		result.addSourceRoot(Sys.getCwd() + "/stdlib");
		result.update("Main.hx", declarations + source);
		return result;
	}

	static function main():Void {
		var result = compiler(valid);
		if (GeneratedProgramRunner.exitCode(result.compile("Main")) != 42)
			throw "nested field assignment lost its array element context";

		for (source in [invalid, invalidStatic]) {
			for (candidate in [result, compiler(valid)]) {
				candidate.update("Main.hx", declarations + source);
				var rejected = false;
				try
					candidate.compile("Main")
				catch (error:CompileError) {
					if (error.diagnostic.code != "E1002")
						throw error;
					rejected = true;
				}
				if (!rejected)
					throw "empty array field assignment inferred Dynamic elements";
			}
		}

		result.update("Main.hx", declarations + valid);
		if (GeneratedProgramRunner.exitCode(result.compile("Main")) != 42)
			throw "restored nested field assignment context failed";
		Sys.println("PASS: nested and static field assignment array context, runtime, rejection, and incremental restoration");
	}
}
