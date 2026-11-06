import compiler.Compiler;
import compiler.runtime.CompilerIntrinsics;
import compiler.hl.HlWriter;

class GeneratedEqualityProvenanceMain {
	static function create(sources:Map<String, String>):Compiler {
		var c = new Compiler();
		CompilerIntrinsics.register(c);
		c.addSourceRoot("stdlib");
		c.livePatching = false;
		c.developmentMetadata = true;
		for (path => source in sources)
			c.update(path, source);
		return c;
	}

	static function main():Void {
		var user = compiler.ir.SourceProvenance.user(new compiler.Source.SourceFile("empty-user.hx", "").span(0, 0));
		var generatedSpan = compiler.Source.SourceSpan.generated("test-helper");
		var generated = compiler.ir.SourceProvenance.user(generatedSpan.merge(generatedSpan));
		if (user.location.sourceHash == 0
			|| generated.location.sourceHash != 0
			|| !Type.enumEq(generated.origin, compiler.ir.SourceProvenance.SourceOrigin.CompilerGenerated("test-helper")))
			throw "Generated spans must have explicit provenance without pretending to name a user snapshot";
		for (valueType in [
			"enum Value implements Equatable { Item(value:Int); }",
			"struct Value implements Equatable { public var value:Int; public function new(value:Int) this.value=value; }",
			"struct Value implements Equatable { public var value:Int; public var text:Null<String>; public var height:Null<Float>; public function new(value:Int) {this.value=value;text=null;height=null;} }"
		]) {
			var value = valueType.indexOf("enum") == 0 ? "Value.Item(1)" : "new Value(1)";
			var sources = [
				"Value.hx" => valueType,
				"A.hx" => "function same(a:Value,b:Value):Bool return a==b;",
				"B.hx" => "class B { public var value:Value; public function new(value:Value) this.value=value; }",
				"Main.hx" => 'function main():Int return A.same(new B($value).value,$value)?42:1;'
			];
			for (path in ["Main.hx", "A.hx", "B.hx", "Value.hx"])
				for (prefix in [false, true]) {
					var edited = sources.copy();
					edited.set(path, prefix ? "\n" + sources.get(path) : sources.get(path) + "\n// comment");
					var c = create(sources);
					c.compile("Main");
					c.update(path, edited.get(path));
					var warmResult = c.compile("Main");
					if (valueType.indexOf("height") >= 0) {
						var generatedOps = 0;
						for (fn in warmResult.ir.functions)
							for (block in fn.blocks)
								for (located in block.instructions)
									switch located.provenance.origin {
										case CompilerGenerated("value-equality"):
											generatedOps++;
											if (located.provenance.location == null || located.provenance.location.sourceHash != 0)
												throw "Built-in equality cannot borrow a caller snapshot";
										default:
									}
						if (generatedOps == 0)
							throw "Nullable primitive equality helpers were not exercised";
					}
					var warm = HlWriter.encode(warmResult.module),
						cold = HlWriter.encode(create(edited).compile("Main").module);
					if (warm.compare(cold) != 0)
						throw 'Shared helper provenance differs after editing $path (prefix=$prefix): $valueType';
				}
		}
		Sys.println("PASS: shared equality helpers retain deterministic provenance and a single current owner");
	}
}
