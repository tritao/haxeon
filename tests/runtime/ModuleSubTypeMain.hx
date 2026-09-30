import compiler.hl.HlWriter;
import compiler.Compiler;
import sys.io.File;

/**
 * A module's secondary type named through its module (`Robot.Part`) resolves in the referring
 * module's package, whether files sit in package folders or directly under a source root, and
 * even when nothing else loads the owning module.
 */
class ModuleSubTypeMain {
	static final ROBOT = "package app; typedef Part = {id:String, link:Int}; class Robot { public static function part(link:Int):Part return {id: \"a\", link: link}; }";
	static final STOCK = "package app; class Stock { final part:Robot.Part; public function new(part:Robot.Part) this.part = part; public function link():Int return part.link; }";
	static final MAIN = "package app; function main():Int return new Stock({id: \"a\", link: 42}).link();";

	static function main():Void {
		// Package folders.
		var nested = new Compiler();
		nested.update("app/Robot.hx", ROBOT);
		nested.update("app/Stock.hx", STOCK);
		nested.update("app/Main.hx", MAIN);
		nested.compile("app.Main");
		// Files of package `app` directly under the source root, as Materia's app keeps them: the
		// owning module must not load a second time under another name.
		var flat = new Compiler();
		flat.update("Robot.hx", ROBOT);
		flat.update("Stock.hx", STOCK);
		flat.update("Main.hx", MAIN);
		var result = flat.compile("Main");
		File.saveBytes(Sys.args()[0], HlWriter.encode(result.module));
	}
}
