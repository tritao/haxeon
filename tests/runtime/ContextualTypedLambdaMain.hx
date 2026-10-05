import compiler.Compiler;
import compiler.Diagnostic.CompileError;
import compiler.hl.HlWriter;
import compiler.runtime.CompilerIntrinsics;
import sys.io.File;

/** Result-annotated callbacks retain contextual parameter inference. */
class ContextualTypedLambdaMain {
	static function rejected(compiler:Compiler, source:String):Void {
		compiler.update("Main.hx", source);
		try {
			compiler.compile("Main");
			throw "Invalid annotated callback accepted";
		} catch (error:CompileError) {
			if (error.diagnostic.code != "E1003" && error.diagnostic.code != "E1009" && error.diagnostic.code != "E1002")
				throw error;
		}
	}

	static function main():Void {
		var compiler = new Compiler();
		CompilerIntrinsics.register(compiler);
		compiler.addSourceRoot("stdlib");
		var prefix = 'class Sink {
		 public function new() {}
		 public function consume<T>(value:T, callback:T->Void):Void callback(value);
		 public function map<T, R>(callback:T->R, value:T):R return callback(value);
		 public function optional(callback:Null<Int>->Int):Int return callback(null);
		}\n';
		rejected(compiler, prefix + 'function main():Int { new Sink().consume(42, function(value):String return "bad"); return 42; }');
		rejected(compiler, prefix + 'function main():Int { new Sink().consume(42, function(value:String):Void {}); return 42; }');
		rejected(compiler, prefix + 'function main():Int { new Sink().consume(42, function(value):Int return "bad"); return 42; }');
		var source = prefix
			+ 'function main():Int {
		 var sink = new Sink(), result = 0;
		 sink.consume(40, function(value):Void { result = value; });
		 var mapped:Int = sink.map(function(value):Int return value + 1, 1);
		 var callback:Int->Int = function(value):Int return value + 2;
		 var optional = sink.optional(function(?value):Int return value == null ? 0 : value);
		 return result + mapped + callback(0) - 2 + optional;
		}';
		compiler.update("Main.hx", source);
		var incremental = compiler.compile("Main");
		var fresh = new Compiler();
		CompilerIntrinsics.register(fresh);
		fresh.addSourceRoot("stdlib");
		fresh.update("Main.hx", source);
		fresh.compile("Main");
		// A formerly valid dependency changing its parameter type must reject.
		rejected(compiler, source.split("consume(40,").join("consume(\"forty\","));
		compiler.update("Main.hx", source);
		File.saveBytes(Sys.args()[0], HlWriter.encode(compiler.compile("Main").module));
		Sys.println("PASS: annotated callback context, generic results, optional parameters and incremental rejection");
	}
}
