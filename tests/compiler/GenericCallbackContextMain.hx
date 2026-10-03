import compiler.Compiler;
import compiler.Diagnostic.CompileError;

class GenericCallbackContextMain {
	static final declarations = 'class Item { public var value:Int; public function new() value = 41; public function dispose():Void value++; } '
		+
		'class Factory<C> { public function new() {} public function make<T>(tag:C, create:Void->T, dispose:T->Void):T { var value = create(); dispose(value); return value; } } '
		+ 'class Resources { public static function make<T>(create:Void->T, dispose:T->Void):T { var value = create(); dispose(value); return value; } '
		+ 'public static function reversed<T>(dispose:T->Void, create:Void->T):T { var value = create(); dispose(value); return value; } '
		+ 'public static function implicit():Int return make(function() return new Item(), function(value) { value.dispose(); }).value; } ';

	static function accepted(expression:String):Void {
		var compiler = new Compiler();
		compiler.update("Main.hx", declarations + 'function main():Int return $expression;');
		if (GeneratedProgramRunner.exitCode(compiler.compile("Main")) != 42)
			throw "Generic callback context produced the wrong result";
	}

	static function main():Void {
		accepted('Resources.implicit()');
		accepted('Resources.make(function() return new Item(), function(value) { value.dispose(); }).value');
		accepted('Resources.reversed(function(value) { value.dispose(); }, function() return new Item()).value');
		accepted('new Factory<String>().make("tag", function() return new Item(), function(value) { value.dispose(); }).value');
		var valid = declarations + 'function main():Int return Resources.make(function() return new Item(), function(value) { value.dispose(); }).value;';
		var compiler = new Compiler();
		compiler.update("Main.hx", valid);
		compiler.compile("Main");
		for (invalid in [
			StringTools.replace(valid, "value.dispose(); }).value", "value.missing(); }).value"),
			StringTools.replace(valid, "function(value) { value.dispose(); }", "function(value:String) {}")
		]) {
			for (candidate in [compiler, new Compiler()]) {
				candidate.update("Main.hx", invalid);
				var rejected = false;
				try
					candidate.compile("Main")
				catch (error:CompileError) {
					if (error.diagnostic.code != "E1007" && error.diagnostic.code != "E1003")
						throw error;
					rejected = true;
				}
				if (!rejected)
					throw "Invalid generic callback was accepted";
			}
			compiler.update("Main.hx", valid);
			if (GeneratedProgramRunner.exitCode(compiler.compile("Main")) != 42)
				throw "Restoring generic callback context failed";
		}
		Sys.println("PASS: generic factory/disposer context, order, runtime and incremental rejection/restoration");
	}
}
