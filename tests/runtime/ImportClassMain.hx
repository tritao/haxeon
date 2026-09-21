import compiler.hl.HlWriter;
import compiler.Compiler;
import sys.io.File;

class ImportClassMain {
	static function main():Void {
		var compiler = new Compiler();
		compiler.addSourceRoot("tests/fixtures");
		compiler.update("editor/widgets/SearchPlugin.hx",
			"package editor.widgets; class SearchPlugin { public var bias:Int; public function new(bias:Int) { this.bias = bias; } public function score(value:Int):Int { return value + this.bias; } } class SearchPluginOptions { public var bias:Int; public function new() { this.bias = 0; } }");
		compiler.update("editor/widgets/SearchPalette.hx",
			"package editor.widgets; class SearchPalette { public var bias:Int; public function new() { this.bias = 0; } }");
		compiler.update("Main.hx",
			"import editor.widgets.SearchPlugin; import editor.widgets.*; function main():Int { var plugin:SearchPlugin = new SearchPlugin(2); var options:SearchPluginOptions = new SearchPluginOptions(); var palette:SearchPalette = new SearchPalette(); var filesystemPalette:FilesystemPalette = new FilesystemPalette(); return plugin.score(40) + options.bias + palette.bias + filesystemPalette.bias; }");
		var result = compiler.compile("Main");
		File.saveBytes(Sys.args()[0], HlWriter.encode(result.module));
	}
}
