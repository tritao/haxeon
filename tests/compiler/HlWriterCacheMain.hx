import compiler.Frontend;
import compiler.hl.HlCode.HlDebugSection;
import compiler.hl.HlValidator;
import compiler.hl.HlWriter;
import compiler.hl.HlWriterCache;
import compiler.ir.hl.HlLower;

/** The writer cache keeps what it learned about a function when the list of debug files changes, except the function's encoding. */
class HlWriterCacheMain {
	static function main():Void {
		var code = HlLower.lower(Frontend.compile("function add(a:Int, b:Int):Int return a + b; function main():Int return add(40, 2);")),
			cache = new HlWriterCache();
		HlWriter.encode(code, cache).flatten();
		for (fn in code.functions)
			expect(cache.isValidated(fn), "a function validated by the first encode stays validated after the writer prepared the cache");
		var function_ = code.functions[0];
		expect(cache.get(function_) != null, "its encoding is cached");
		cache.prepare(["other.hx"]);
		expect(cache.isValidated(function_), "a new debug file list keeps validation marks");
		expect(cache.get(function_) == null, "a new debug file list drops the encodings, which name files by index");
		Sys.println("PASS: writer cache validation marks survive a new debug file list");

		// The snapshot section is compared with its model only under HAXEON_CHECK_REUSE=1 (both come from the same model otherwise).
		var content = haxe.io.Bytes.ofString("class A {}"),
			hash:Int = cast 0x811C9DC5;
		for (index in 0...content.length)
			hash = (hash ^ content.get(index)) * 16777619;
		var tampered = HlLower.lower(Frontend.compile("function main():Int return 1;"));
		tampered.sourceSnapshots = [{sourceHash: hash, content: content}];
		tampered.debugSections.push(HlDebugSection.of(HlWriter.SOURCE_SNAPSHOTS, 1, 0, haxe.io.Bytes.ofString("not the model")));
		var original = Sys.getEnv("HAXEON_CHECK_REUSE");
		Sys.putEnv("HAXEON_CHECK_REUSE", "0");
		HlValidator.validate(tampered);
		Sys.putEnv("HAXEON_CHECK_REUSE", "1");
		var caught = false;
		try
			HlValidator.validate(tampered)
		catch (error:Dynamic)
			caught = Std.string(error).indexOf("does not match its model") >= 0;
		Sys.putEnv("HAXEON_CHECK_REUSE", original == null ? "0" : original);
		expect(caught, "a snapshot section that differs from its model must be reported when checking");
		Sys.println("PASS: the snapshot section is checked against its model when checking");
	}

	static function expect(condition:Bool, message:String):Void {
		if (!condition)
			throw message;
	}
}
