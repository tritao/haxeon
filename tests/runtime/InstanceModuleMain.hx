import compiler.hl.HlWriter;
import compiler.Compiler;
import sys.io.File;

class InstanceModuleMain {
	static function main():Void {
		var compiler = new Compiler();
		compiler.update("Main.hx",
			"class Box { public var value:Int = 40; public function new(value:Int) { this.value = this.value + value; } public function get():Int { return this.value; } } function main():Int { var box = new Box(2); return box.get(); }");
		var result = compiler.compile("Main");
		if (!result.functionIndices.exists("Box.new") || !result.functionIndices.exists("Box.get"))
			throw "Incremental compiler did not retain instance methods";
		File.saveBytes(Sys.args()[0], HlWriter.encode(result.module));
		Sys.println("PASS: incremental instance class compiled");
	}
}
