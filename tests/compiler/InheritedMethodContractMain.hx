import compiler.Compiler;
import compiler.Diagnostic.CompileError;

/** An inherited method name is a virtual slot, even when the subclass declaration is private. */
class InheritedMethodContractMain {
	static final base = 'class Base {public function new(){} public function connector(name:String):Int return 42;}';
	static final invalid = [
		'function connector():Int return 1;',
		'private function connector():Int return 1;',
		'public function connector(name:Int):Int return name;',
		'public function connector(name:String):String return name;',
		'private function connector(name:String):Int return 1;',
		'private function connector(name:String) return 1;',
		'public static function connector(name:String):Int return 1;'
	];

	static function child(method:String):String
		return 'class Child extends Base {public function new(){super();} $method}';

	static function reject(c:Compiler):Void {
		try
			c.compile("Main")
		catch (error:CompileError) {
			if (error.diagnostic.code != "E1020" || error.diagnostic.message.indexOf("inherited") < 0)
				throw error;
			return;
		}
		throw "An incompatible inherited method was accepted";
	}

	static function main():Void {
		var warm = new Compiler();
		for (method in invalid)
			for (c in [warm, new Compiler()]) {
				c.update("Base.hx", base);
				c.update("Child.hx", child(method));
				c.update("Main.hx", 'function main():Int {var x:Base=new Child();return x.connector("power");}');
				reject(c);
			}
		for (method in [
			'function connectorBody():Int return 1;',
			'override public function connector(name:String):Int return 42;',
			'override function connector(name:String):Int return 42;',
			'override function connector(name:String) return 42;'
		]) {
			warm.update("Child.hx", child(method));
			if (GeneratedProgramRunner.exitCode(warm.compile("Main")) != 42)
				throw "A valid inherited method stopped dispatching correctly";
		}
		// A base signature edit must invalidate an unchanged subclass, even without semantic indexing.
		warm.update("Base.hx", base.split("name:String").join("name:Int"));
		reject(warm);
		warm.update("Base.hx", base);
		if (GeneratedProgramRunner.exitCode(warm.compile("Main", null, false)) != 42)
			throw "Recovery after an invalid base signature failed";
		// Explicit visibility changes are signature changes, not just body edits.
		warm.update("Base.hx", base.split("public function connector").join("private function connector"));
		warm.update("Child.hx", child('private function connector(name:String):Int return 42;'));
		warm.compile("Main", null, false);
		warm.update("Base.hx", base);
		reject(warm);
		var generic = new Compiler();
		generic.update("Base.hx", 'class Base<T> {public function new(){} public function connector(name:T):T return name;}');
		generic.update("Middle.hx", 'class Middle<U> extends Base<U> {public function new(){super();}}');
		generic.update("Child.hx", 'class Child extends Middle<Int> {public function new(){super();} public function connector(name:Int):Int return name;}');
		generic.update("Main.hx", 'function main():Int {var x:Base<Int>=new Child();return x.connector(42);}');
		if (GeneratedProgramRunner.exitCode(generic.compile("Main")) != 42)
			throw "Generic inheritance substitutions were not respected";
		generic.update("Child.hx", 'class Child extends Middle<Int> {public function new(){super();} public function connector(name:String):Int return 42;}');
		reject(generic);
		Sys.println("PASS: inherited method signature and visibility contracts, cold, incremental and generic bases");
	}
}
