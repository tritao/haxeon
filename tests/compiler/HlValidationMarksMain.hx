import compiler.Frontend;
import compiler.hl.HlCode.HlDebugSection;
import compiler.hl.HlValidationMarks;
import compiler.hl.HlValidator;
import compiler.hl.HlWriter;
import compiler.hl.lower.HlLower;

/** The validator marks what it checked, keeps the marks of the module just written, and checks a snapshot section against its model. */
class HlValidationMarksMain {
	static function main():Void {
		var code =
			HlLower.lower(Frontend.compile("function add(a:Int, b:Int):Int return a + b; function main():Int return add(40, 2);")),
			marks = new HlValidationMarks();
		HlValidator.validate(code, marks);
		for (fn in code.functions)
			expect(marks.isValidated(fn), "a validated function is marked");
		var kept = code.functions[0];
		marks.retainFunctions([kept]);
		expect(marks.isValidated(kept), "the marks of the functions kept stay");
		expect(!marks.isValidated(code.functions[1]), "the marks of the functions left out go");
		Sys.println("PASS: validation marks follow the functions written");

		// The snapshot section is compared with its model only when the compile checks its reuse (both come from the same model otherwise).
		var content = haxe.io.Bytes.ofString("class A {}"),
			hash:Int = cast 0x811C9DC5;
		for (index in 0...content.length)
			hash = (hash ^ content.get(index)) * 16777619;
		var tampered = HlLower.lower(Frontend.compile("function main():Int return 1;"));
		tampered.sourceSnapshots = [{sourceHash: hash, content: content}];
		tampered.debugSections.push(HlDebugSection.of(HlWriter.SOURCE_SNAPSHOTS, 1, 0,
			haxe.io.Bytes.ofString("not the model")));
		HlValidator.validate(tampered, null, false);
		var caught = false;
		try
			HlValidator.validate(tampered, null, true)
		catch (error:Dynamic)
			caught = Std.string(error).indexOf("does not match its model") >= 0;
		expect(caught, "a snapshot section that differs from its model must be reported when checking");
		Sys.println("PASS: the snapshot section is checked against its model when checking");
	}

	static function expect(condition:Bool, message:String):Void {
		if (!condition)
			throw message;
	}
}
