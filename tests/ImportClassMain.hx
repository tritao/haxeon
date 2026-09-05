import compiler.hl.HlWriter;
import compiler.modules.Compiler;
import sys.io.File;

class ImportClassMain {
	static function main():Void {
		var compiler = new Compiler();
		compiler.update("editor/widgets/SearchPlugin.hx",
			"class SearchPlugin { public var bias:Int; public function new(bias:Int) { this.bias = bias; } public function score(value:Int):Int { return value + this.bias; } }");
		compiler.update("Main.hx",
			"import editor.widgets.SearchPlugin; function main():Int { var plugin:SearchPlugin = new SearchPlugin(2); return plugin.score(40); }");
		var result = compiler.compile("Main");
		File.saveBytes(Sys.args()[0], HlWriter.encode(result.module));
	}
}
