import compiler.Compiler;
import compiler.core.Diagnostic.CompileError;
import compiler.ir.tools.IrInterpreter;
import compiler.runtime.CompilerIntrinsics;

/** A write through one name invalidates refinements of the same field through aliases; a setter call, what its body can change. */
class FieldAliasFlowMain {
	static function main():Void {
		var compiler = new Compiler(),
			source = 'class Cell { public var item:Null<Int>; public var keep:Null<Int>; '
				+ 'public function new() { item=null; keep=9; } } '
				+ 'function main():Int { var first=new Cell(); var alias=first; first.item=null; first.keep=9; alias.item=41; '
				+ 'return first.item == null ? 0 : first.item + first.keep; }';
		for (expected in [50, 51, 50]) {
			compiler.update("Main.hx",
				expected == 51 ? StringTools.replace(source, "alias.item=41", "alias.item=42") : source);
			var compiled = compiler.compile("Main"),
				interpreted = new IrInterpreter(compiled.ir).run("main"),
				native = GeneratedProgramRunner.exitCode(compiled);
			if (interpreted != expected || native != expected)
				throw 'field alias flow expected $expected, interpreter=$interpreted, HashLink=$native';
		}
		var dynamicCompiler = new Compiler();
		CompilerIntrinsics.register(dynamicCompiler);
		dynamicCompiler.addStandardLibrarySourceRoot("stdlib");
		dynamicCompiler.update("Main.hx", 'class Cell { public var item:Null<Int>; public function new() item=null; } '
			+ 'function main():Int { var first=new Cell(); var alias:Dynamic=first; first.item=null; alias.item=42; '
			+ 'return first.item == null ? 0 : first.item; }');
		var dynamicResult = GeneratedProgramRunner.exitCode(dynamicCompiler.compile("Main"));
		if (dynamicResult != 42) throw 'Dynamic field alias returned $dynamicResult';
		var setter = new Compiler();
		// The fact is observed through a nullable reference, whose field needs the null check to still hold.
		setter.update("Main.hx", 'class Box { public final n:Int; public function new(n:Int) this.n = n; } '
			+ 'class Cell { public var item:Null<Box>; public var trigger(get,set):Int; '
			+ 'public function new() item=new Box(1); function get_trigger():Int return 0; function set_trigger(v:Int):Int { item=null; return v; } } '
			+ 'function main():Int { var cell=new Cell(); if (cell.item != null) { cell.trigger=1; return cell.item.n + 1; } return 0; }');
		var rejected = false;
		try setter.compile("Main") catch (error:CompileError) rejected = error.diagnostic.code == "E1005";
		if (!rejected) throw "property setter preserved a field refinement across its side effects";
		var inlineClearing = new Compiler();
		inlineClearing.update("Main.hx", 'class Box { public final n:Int; public function new(n:Int) this.n = n; } '
			+ 'class Cell { public var item:Null<Box>; public var trigger(get,set):Int; '
			+ 'public function new() item=new Box(1); function get_trigger():Int return 0; '
			+ 'inline function set_trigger(v:Int):Int { item=null; return v; } } '
			+ 'function main():Int { var cell=new Cell(); if (cell.item != null) { cell.trigger=1; return cell.item.n + 1; } return 0; }');
		rejected = false;
		try inlineClearing.compile("Main") catch (error:CompileError) rejected = error.diagnostic.code == "E1005";
		if (!rejected) throw "an inline setter that clears the narrowed field preserved its refinement";
		inlineSetterKeepsOtherRefinements();
		Sys.println("PASS: field writes invalidate alias refinements through incremental edits");
	}

	/**
		An inline setter's body is part of the call: one that stores only its own fields keeps the refinement of the field that
		holds its object, until an edit gives it an effect it cannot see past.
	 */
	static function inlineSetterKeepsOtherRefinements():Void {
		// The setter is another module's, so the edit changes only its body and the caller is rebuilt for reading it.
		var style =
			'class Style { public var width(default, set):Int; public var height(default, set):Int; '
			+ 'public var assigned(default, null):Int; public function new() { width = 0; height = 0; assigned = 0; } '
			+ 'inline function set_width(v:Int):Int { assigned |= 1; return width = v; } '
			+ 'inline function set_height(v:Int):Int { this.assigned |= 2; return this.height = v; } } '
			+ 'class Log { public static var items:Array<Int> = []; public static function add(v:Int) items.push(v); }',
			compiler = new Compiler();
		compiler.update("Style.hx", style);
		compiler.update("Main.hx",
			'class Options { public var style:Null<Style>; public function new() style = null; } '
			+ 'function main():Int { var options = new Options(); options.style = new Style(); '
			+ 'options.style.width = 40; options.style.height = 2; return options.style.width + options.style.height; }');
		var compiled = compiler.compile("Main"), value = new IrInterpreter(compiled.ir).run("main");
		if (value != 42)
			throw 'inline setters that store their own fields returned $value instead of 42';
		compiler.update("Style.hx", StringTools.replace(style, "{ assigned |= 1;", "{ Log.add(v); assigned |= 1;"));
		var rejected = false;
		try compiler.compile("Main") catch (error:CompileError) rejected = error.diagnostic.code == "E1005";
		if (!rejected)
			throw "an edit that gave an inline setter an unknown effect kept the refinement its callers relied on";
	}
}
