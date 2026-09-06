import compiler.hl.HlWriter;
import compiler.Compiler;
import sys.io.File;

class NamespaceMain {
	static function main():Void {
		var compiler = new Compiler();
		compiler.update("left/Item.hx", "package left; class Item { public var value:Int; public function new(value:Int):Void { this.value = value; } }");
		compiler.update("right/Item.hx", "package right; class Item { public var value:Int; public function new(value:Int):Void { this.value = value; } }");
		compiler.update("Main.hx",
			"package app; function main():Int { var left = new left.Item(10); var right = new right.Item(32); return left.value + right.value; }");
		var result = compiler.compile("Main");
		if (!result.functionIndices.exists("left.Item.new") || !result.functionIndices.exists("right.Item.new"))
			throw "qualified nominal declarations collided";
		File.saveBytes(Sys.args()[0], HlWriter.encode(result.module));
	}
}
