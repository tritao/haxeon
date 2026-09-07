import compiler.hl.HlWriter;
import compiler.Compiler;
import compiler.types.Type.CompilerType;
import sys.io.File;

class CollectionMain {
	static function main():Void {
		var compiler = new Compiler();
		compiler.registerNative("array_int_init", "realtime_runtime", "array_int_init", [CompilerType.TInstance(Class, "IntArray", [])], CompilerType.TVoid);
		compiler.registerNative("array_int_push", "realtime_runtime", "array_int_push", [CompilerType.TInstance(Class, "IntArray", []), CompilerType.TInt],
			CompilerType.TVoid);
		compiler.registerNative("array_int_get", "realtime_runtime", "array_int_get", [CompilerType.TInstance(Class, "IntArray", []), CompilerType.TInt],
			CompilerType.TInt);
		compiler.registerNative("array_int_length", "realtime_runtime", "array_int_length", [CompilerType.TInstance(Class, "IntArray", [])], CompilerType.TInt);
		compiler.update("Main.hx",
			"class IntArray { public var storage:String; public var length:Int; public function new() { array_int_init(this); } public function push(value:Int):Void { array_int_push(this, value); } public function get(index:Int):Int { return array_int_get(this, index); } } function main():Int { var values = new IntArray(); values.push(41); return values.get(0) + values.length; }");
		var result = compiler.compile("Main");
		File.saveBytes(Sys.args()[0], HlWriter.encode(result.module));
	}
}
