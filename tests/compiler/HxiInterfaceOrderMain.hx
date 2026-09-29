import compiler.ffi.HxiInterfaceOrder;

/** FFI interfaces are registered dependencies first, whatever order their files sort in. */
class HxiInterfaceOrderMain {
	static function source(name:String, dependencies:Array<String>):String {
		var depends = dependencies.length == 0 ? "" : ' @depends(${[for (d in dependencies) '"$d"'].join(", ")})';
		return 'interface $name @target("portable-abi64") @library("$name")$depends {\n}\n';
	}

	static function names(sources:Array<{path:String, text:String}>):String
		return [for (s in sources) s.path].join(",");

	static function main():Void {
		// robotkit/policy/... sorts before robotkit/runtime/..., yet depends on it.
		var sorted = [
			{path: "a-policy.hxi", text: source("Policy", ["Runtime"])},
			{path: "b-runtime.hxi", text: source("Runtime", [])},
			{path: "c-simkit.hxi", text: source("SimKit", ["Runtime", "Other"])},
			{path: "d-other.hxi", text: source("Other", ["Runtime"])}
		];
		var ordered = names(HxiInterfaceOrder.dependenciesFirst(sorted));
		if (ordered != "b-runtime.hxi,a-policy.hxi,d-other.hxi,c-simkit.hxi")
			throw 'dependencies did not come first: $ordered';
		Sys.println("PASS: interfaces come after the interfaces they depend on");

		var already = [
			{path: "1.hxi", text: source("A", [])},
			{path: "2.hxi", text: source("B", ["A"])},
			{path: "3.hxi", text: source("C", [])}
		];
		if (names(HxiInterfaceOrder.dependenciesFirst(already)) != "1.hxi,2.hxi,3.hxi")
			throw "an order that already satisfies the dependencies must not change";
		Sys.println("PASS: an already ordered list stays as it is");

		// Unknown and cyclic dependencies are the compiler's to report; the order must not hang or drop files.
		var odd = [
			{path: "x.hxi", text: source("X", ["Missing"])},
			{path: "y.hxi", text: source("Y", ["Z"])},
			{path: "z.hxi", text: source("Z", ["Y"])}
		];
		if (HxiInterfaceOrder.dependenciesFirst(odd).length != 3)
			throw "files were dropped";
		Sys.println("PASS: unknown and cyclic dependencies are left for the compiler to report");
	}
}
