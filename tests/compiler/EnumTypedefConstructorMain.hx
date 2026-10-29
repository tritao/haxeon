import compiler.Compiler;
import compiler.Compiler.CompileResult;
import compiler.Diagnostic.CompileError;
import compiler.hl.HlWriter;
import compiler.runtime.CompilerIntrinsics;
import compiler.backend.wasm.WasmBackend;
import compiler.backend.Backend.BackendTarget;
import sys.io.File;

class EnumTypedefConstructorMain {
	static final SOURCE = 'package document; enum SourceEdit { InsertBlock(path:Array<String>, block:String); Empty; }';
	static final OTHER = 'package document; enum OtherEdit { Empty; InsertBlock(path:Array<String>, block:String); }';
	static final BODY = 'var edit=Edit.InsertBlock(["root"],"hello"); return switch edit { case Edit.InsertBlock(path,block): path.length + block.length + 36; case Edit.Empty: 0; };';

	static function compiler(alias = 'SourceEdit'):Compiler {
		var result = new Compiler();
		CompilerIntrinsics.register(result);
		result.addSourceRoot("stdlib");
		result.update("document/SourceEdit.hx", SOURCE);
		result.update("document/OtherEdit.hx", OTHER);
		result.update("document/Edits.hx", 'package document; typedef Edit = $alias;');
		result.update("document/Cell.hx", 'package document; enum Cell<T> { Value(value:T); Missing; }');
		result.update("document/Cells.hx", 'package document; typedef IntCell = Cell<Int>;');
		return result;
	}

	static function program(body:String):String
		return 'import document.Edits.Edit; function main():Int { $body }';

	static function main():Void {
		var c = compiler();
		c.update("Main.hx", program(BODY));
		var clean = c.compile("Main");
		execute(clean, 42);
		wasm(clean, "clean");
		c.update("document/Edits.hx", "package document; typedef Edit = OtherEdit;");
		var changed = c.compile("Main");
		if (changed.retyped.indexOf("main") < 0)
			throw "Retargeting a typedef must retype its constructor caller";
		execute(changed, 42);
		wasm(changed, "incremental");
		c.update("document/Edits.hx", "package document; typedef Edit = SourceEdit;");
		execute(c.compile("Main"), 42);

		for (body in [
			'return switch Edit.Empty { case Edit.Empty: 42; case Edit.InsertBlock(_, _): 0; };',
			'var edit=Edit.Empty; return edit == Edit.Empty ? 42 : 0;',
			'var edit:Edit=InsertBlock(["root"],"hello"); return switch edit { case InsertBlock(path,block): path.length + block.length + 36; case Empty: 0; };',
			'return switch document.Edits.Edit.InsertBlock([],"hello") { case document.Edits.Edit.InsertBlock(_,s): s.length + 37; case document.Edits.Edit.Empty: 0; };'
		]) {
			var next = compiler();
			next.update("Main.hx", program(body));
			execute(next.compile("Main"), 42);
		}
		var chained = compiler("Forward");
		chained.update("document/Forward.hx", "package document; typedef Forward = SourceEdit;");
		chained.update("Main.hx", program(BODY));
		execute(chained.compile("Main"), 42);
		chained.update("document/Forward.hx", "package document; typedef Forward = OtherEdit;");
		execute(chained.compile("Main"), 42);

		var generic = compiler();
		generic.update("Main.hx",
			'import document.Cells.IntCell; function main():Int { var cell=IntCell.Value(42); return switch cell { case IntCell.Value(n): n; case IntCell.Missing: 0; }; }');
		var bound = generic.compile("Main");
		execute(bound, 42);
		wasm(bound, "bound");

		// A caller that uses the alias only as a nullary value must also be invalidated.
		var nullary = compiler();
		nullary.update("Main.hx", program('return Edit.Empty == Edit.Empty ? 42 : 0;'));
		execute(nullary.compile("Main"), 42);
		nullary.update("document/Edits.hx", "package document; typedef Edit = OtherEdit;");
		execute(nullary.compile("Main"), 42);
		// The qualifier in a pattern is a dependency even when the subject names the real enum.
		var pattern = compiler();
		pattern.update("Main.hx",
			program('var value=document.SourceEdit.InsertBlock([],"x"); return switch value { case Edit.InsertBlock(_, _): 42; case Edit.Empty: 0; };'));
		execute(pattern.compile("Main"), 42);
		pattern.update("document/Edits.hx", "package document; typedef Edit = OtherEdit;");
		reject(pattern, "E1019");

		for (body in [
			'return Edit.NoSuchCase();',
			'return Edit.InsertBlock();',
			'var e=Edit.InsertBlock([1],"x"); return 0;'
		]) {
			var bad = compiler();
			bad.update("Main.hx", program(body));
			reject(bad);
		}
		for (body in [
			'var cell=IntCell.Value("wrong"); return 0;',
			'var cell:document.Cell<String>=IntCell.Value(42); return 0;',
			'var cell:document.Cell<String>=IntCell.Missing; return 0;'
		]) {
			var bad = compiler();
			bad.update("Main.hx", 'import document.Cells.IntCell; function main():Int { $body }');
			reject(bad);
		}
		var duplicate = compiler();
		duplicate.update("document/Edit.hx", "package document; enum Edit { InsertBlock(block:String); }");
		duplicate.update("document/Edits.hx", "package document; typedef Edit = document.Edit;");
		duplicate.update("Main.hx", program('var e=Edit.InsertBlock("test"); return 0;'));
		reject(duplicate, "E1020");
		Sys.println("PASS: typedef-qualified enum calls, values, patterns and generic bindings; clean/incremental dependency tracking");
	}

	static function reject(c:Compiler, ?code:String):Void {
		try {
			c.compile("Main");
		} catch (error:CompileError) {
			if (code != null && error.diagnostic.code != code)
				throw error;
			return;
		}
		throw "Invalid enum typedef use was accepted";
	}

	static function execute(result:CompileResult, expected:Int):Void {
		var path = "out/enum-typedef-constructor.hl";
		File.saveBytes(path, HlWriter.encode(result.module));
		var child = new sys.io.Process(".tools/hashlink/hl", [path]);
		var output = child.stdout.readAll().toString() + child.stderr.readAll().toString();
		var status = child.exitCode();
		child.close();
		if (status != expected)
			throw 'enum typedef returned $status: $output';
	}

	static function wasm(result:CompileResult, label:String):Void {
		for (target in [Wasm32, WasmGc])
			File.saveBytes('out/enum-typedef-$target-$label.wasm', new WasmBackend().compile(result.ir, {target: target, debugNames: true}).bytes);
	}
}
