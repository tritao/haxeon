import compiler.abi.PositionalName;
import compiler.semantic.LambdaName;

class LambdaNameMain {
	static function main():Void {
		var name = LambdaName.of("demo.Main.run", "run#2");
		expect(name == "$lambda:demo.Main.run:run#2" && LambdaName.is(name), "a lambda name reads $lambda:<enclosing>:<member>#<ordinal>");
		expect(LambdaName.enclosing(name) == "demo.Main.run", "the enclosing function is read back");
		expect(LambdaName.enclosing("demo.Main.run") == null && !LambdaName.is("demo.Main.run"), "a plain function is not a lambda");

		var nested = LambdaName.of(name, "run#0");
		expect(LambdaName.enclosing(nested) == name, "the enclosing name of a nested lambda is the outer lambda");
		expect(LambdaName.outermost(nested) == "demo.Main.run", "the outermost function is found through every level of nesting");
		expect(LambdaName.outermost("demo.Main.run") == "demo.Main.run", "a function is its own outermost function");

		// A generic specialization's name contains colons; the enclosing name is everything up to the last one.
		var specialization = "$generic:demo.Box.get[layout]<class:demo.Item>",
			inSpecialization = LambdaName.of(specialization, "get#0");
		expect(LambdaName.enclosing(inSpecialization) == specialization, "colons inside the enclosing name are kept");
		expect(LambdaName.outermost(LambdaName.of(inSpecialization, "get#1")) == specialization, "nesting inside a specialization resolves to it");

		expect(PositionalName.is(nested)
			&& PositionalName.group(nested) == "$lambda:" + name + ":run"
			&& PositionalName.ordinal(nested) == 0,
			"a nested lambda's siblings are the lambdas of its enclosing lambda");
		expect(PositionalName.group(name) == "$lambda:demo.Main.run:run"
			&& PositionalName.ordinal(name) == 2, "a lambda's group and ordinal are read back");
		var adapter = "$function-adapter:" + name + ":3";
		expect(PositionalName.is(adapter)
			&& PositionalName.group(adapter) == "$function-adapter:" + name
			&& PositionalName.ordinal(adapter) == 3,
			"an adapter's group is its context, whose name may contain colons");
		expect(!PositionalName.is("demo.Main.run"), "a declared function is not positionally named");

		expect(LambdaName.enclosing("$lambda:") == null
			&& LambdaName.enclosing("$lambda:x") == null, "a malformed name has no enclosing function");
		expect(LambdaName.outermost("$lambda:x") == "$lambda:x", "a malformed name is returned unchanged");

		Sys.println("PASS: lambda names");
	}

	static function expect(condition:Bool, message:String):Void {
		if (!condition)
			throw message;
	}
}
