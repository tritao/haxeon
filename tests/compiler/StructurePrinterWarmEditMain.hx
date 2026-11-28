using compiler.compilation.BackendArtifact.BackendArtifacts;

import compiler.CompileOptions;
import compiler.Compiler;
import compiler.ir.model.IrFunction;
import compiler.ir.model.IrSymbol;
import compiler.ir.pipeline.IrProgramAssembler;
import compiler.runtime.CompilerIntrinsics;

/**
 * A warm build keeps an anonymous structure's printer (`IrProgramAssembler.anonymousString`) while the structure's object is the
 * same, and makes it again when an edit changes the object under the same name: `Meters` taking another underlying type changes
 * how `{distance:Meters}` stores its field, not the structure's name. The other structure's printer is the one the first build
 * made, and the warm module is the fresh one's, in a build as it is and in one checking its reuse.
 */
class StructurePrinterWarmEditMain {
	static final metersSource = "abstract Meters(Int) from Int to Int {}";
	static final metersFloat = "abstract Meters(Float) from Float to Float {}";
	static final mainSource =
		"class Main { static function main():Int { var labeled = {label: \"x\"}; var measured = {distance: (3 : Meters)}; "
		+ "return Std.string(labeled).length + Std.string(measured).length; } }";

	static function main():Void {
		for (check in [false, true]) {
			var files = ["Meters.hx" => metersSource, "Main.hx" => mainSource], compiler = newCompiler(files, check);
			compiler.compile("Main");
			var labeled = printer(compiler, "label"), measured = printer(compiler, "distance");
			files.set("Meters.hx", metersFloat);
			compiler.update("Meters.hx", metersFloat);
			var warm = compiler.compile("Main"), fresh = newCompiler(files, false).compile("Main");
			if (printer(compiler, "label") != labeled)
				throw 'the printer of a structure the edit leaves as it was is made again (check: $check)';
			var remade = printer(compiler, "distance");
			if (remade == measured || remade.name != measured.name)
				throw 'the printer of a structure whose field the edit stores as another type is not made again (check: $check)';
			var warmBytes = warm.artifact.hashLink().hashLinkBytes().flatten(),
				freshBytes = fresh.artifact.hashLink().hashLinkBytes().flatten();
			if (warmBytes.compare(freshBytes) != 0)
				throw 'the warm module differs from a fresh one (${warmBytes.length} and ${freshBytes.length} bytes, check: $check)';
		}
		Sys.println("PASS: a warm build keeps a structure's printer while its object is the same and makes it again when it changes");
	}

	/** The printer the session keeps for the structure whose first field is `field`. */
	static function printer(compiler:Compiler, field:String):IrFunction {
		for (structure in compiler.state.lastTypedProgram.anonymousTypes)
			if (structure.fields.length > 0 && structure.fields[0].name == field) {
				var name = structure.name,
					kept =
						compiler.state.irGeneration.kept(IrSymbol.of(IrProgramAssembler.anonymousStringName(name)).id);
				if (kept == null)
					throw 'the structure "$name" has no printer kept with its object';
				return kept;
			}
		throw 'no structure has the field "$field"';
	}

	static function newCompiler(files:Map<String, String>, check:Bool):Compiler {
		var compiler = new Compiler(null, CompilerIntrinsics.configuration());
		compiler.livePatching = false;
		compiler.options = new CompileOptions({checkReuse: check});
		compiler.addSourceRoot("stdlib");
		for (path => text in files)
			compiler.update(path, text);
		return compiler;
	}
}
