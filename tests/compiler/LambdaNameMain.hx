import compiler.semantic.LambdaName;

class LambdaNameMain {
	static function main():Void {
		var name = LambdaName.of("demo.Main.run", 42);
		expect(name == "$lambda:demo.Main.run:42" && LambdaName.is(name), "a lambda name reads $lambda:<enclosing>:<offset>");
		expect(LambdaName.enclosing(name) == "demo.Main.run", "the enclosing function is read back");
		expect(LambdaName.enclosing("demo.Main.run") == null && !LambdaName.is("demo.Main.run"), "a plain function is not a lambda");

		var nested = LambdaName.of(name, 7);
		expect(LambdaName.enclosing(nested) == name, "the enclosing name of a nested lambda is the outer lambda");
		expect(LambdaName.outermost(nested) == "demo.Main.run", "the outermost function is found through every level of nesting");
		expect(LambdaName.outermost("demo.Main.run") == "demo.Main.run", "a function is its own outermost function");

		// A generic specialization's name contains colons; the enclosing name is everything up to the last one.
		var specialization = "$generic:demo.Box.get[layout]<class:demo.Item>",
			inSpecialization = LambdaName.of(specialization, 3);
		expect(LambdaName.enclosing(inSpecialization) == specialization, "colons inside the enclosing name are kept");
		expect(LambdaName.outermost(LambdaName.of(inSpecialization, 9)) == specialization, "nesting inside a specialization resolves to it");

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
