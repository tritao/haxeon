import compiler.compilation.CompilationContext;

class DependencyKeyMain {
	static function main():Void {
		var lists = [
			[],
			[""],
			["", ""],
			["a", "bc"],
			["ab", "c"],
			["a:b"],
			["a", "b"],
			["a:b", "c"],
			["a", "b:c"],
			["é", "😀"],
			["😀", "é"]
		];
		var keys:Map<String, Bool> = [];
		for (dependencies in lists) {
			var key = CompilationContext.dependencyKey(dependencies);
			for (index in 0...key.length)
				if (key.charCodeAt(index) == 0)
					throw "dependency key cannot be encoded as a HashLink string";
			if (keys.exists(key))
				throw "different dependency lists collided";
			keys.set(key, true);
			if (key != CompilationContext.dependencyKey(dependencies.copy()))
				throw "dependency key is not stable";
		}
		Sys.println("PASS: dependency key stability, distinct boundaries, empty components and Unicode");
	}
}
