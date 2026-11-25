import compiler.Compiler;
import compiler.runtime.CompilerIntrinsics;

/**
 * A shared generated helper is a function of its type and operation, never of the function that happened to ask for it first
 * (`session.generatedFunctionOrigin`, `HelperOwner`): the code, the source attribution and the program's behavior are the same whether
 * one module or two ask for it, whichever of them is typed first, and after the first asker is edited away in a warm session.
 * Covered: the value equality helper of a declared struct and of a structural type (an array of it), the enum equality helper of an array of an enum.
 */
class HelperRequesterIndependenceMain {
	static final declarations = [
		"Inner.hx"
			=> "struct Inner implements Equatable { public var a:Int; public function new(a:Int) { this.a = a; } }",
		"Color.hx" => "enum Color { Red; Green; }"
	];

	static function user(name:String, compares:Bool):String
		return "class "
			+ name
			+ " { public static function same(a:Array<Inner>, b:Array<Inner>, c:Array<Color>, d:Array<Color>):Bool return "
			+ (compares ? "haxeon.Equality.equals(a, b) && haxeon.Equality.equals(c, d)" : "true")
			+ "; }";

	static final mainSource =
		"class Main { public static function main():Int { var l = [new Inner(1)]; var c = [Color.Red, Color.Green]; "
		+ "return (AUser.same(l, l, c, c) ? 1 : 0) + (ZUser.same(l, l, c, c) ? 10 : 0); } }";

	static function newCompiler(live:Bool):Compiler {
		var c = new Compiler(null, CompilerIntrinsics.configuration());
		c.livePatching = live;
		c.addStandardLibrarySourceRoot("stdlib");
		c.configure("independence", "independence", compiler.tools.CompilerDriver.targetDefines("hl"));
		for (name => text in declarations)
			c.update(name, text);
		c.update("Main.hx", mainSource);
		return c;
	}

	/** The shared helpers of the program: name, source files named by their instructions, and code fingerprint. */
	static function helpers(result:compiler.Compiler.CompileResult):Map<String, String> {
		var found:Map<String, String> = [];
		for (fn in result.ir.functions)
			if (StringTools.startsWith(fn.name, "$value$equality:")
				|| StringTools.startsWith(fn.name, "$enum-equals:")) {
				var paths:Array<String> = [];
				for (block in fn.blocks)
					for (located in block.instructions) {
						var location = located.provenance.location;
						var path = location == null ? null : compiler.core.SourceAnchor.at(location.anchor).path;
						if (path != null && paths.indexOf(path) < 0)
							paths.push(path);
					}
				found.set(fn.name, paths.join("|") + " " + compiler.ir.codec.IrFunctionStateCodec.codeFingerprint(fn));
			}
		return found;
	}

	static function show(found:Map<String, String>):String {
		var names = [for (name in found.keys()) name];
		names.sort(Reflect.compare);
		return [for (name in names) name.substr(0, 40) + " -> " + found.get(name)].join("\n");
	}

	static function same(label:String, left:Map<String, String>, right:Map<String, String>):Void {
		if (show(left) != show(right))
			throw '$label differs:\n${show(left)}\n--\n${show(right)}';
	}

	static function main():Void {
		for (live in [false, true])
			scenarios(live);
		Sys.println("PASS: shared generated helpers do not depend on which function asked for them, cold or warm, plain or live");
	}

	static function scenarios(live:Bool):Void {
		// Both modules ask, and AUser (typed first) is the asker that used to be kept.
		var both = newCompiler(live);
		both.update("AUser.hx", user("AUser", true));
		both.update("ZUser.hx", user("ZUser", true));
		var bothHelpers = helpers(both.compile("Main"));
		if (Lambda.count(bothHelpers) < 3)
			throw 'Expected the helpers of Inner, Array<Inner> and Array<Color>: ${show(bothHelpers)}';

		// Only ZUser asks.
		var only = newCompiler(live);
		only.update("AUser.hx", user("AUser", false));
		only.update("ZUser.hx", user("ZUser", true));
		same((live ? "live " : "plain ") + "one asker against two askers (cold)", helpers(only.compile("Main")),
			bothHelpers);

		// Warm: AUser stops asking after the helpers were made on its behalf.
		var warm = newCompiler(live);
		warm.update("AUser.hx", user("AUser", true));
		warm.update("ZUser.hx", user("ZUser", true));
		warm.compile("Main");
		warm.update("AUser.hx", user("AUser", false));
		var warmResult = warm.compile("Main");
		same((live ? "live " : "plain ") + "warm after the first asker stopped asking against cold",
			helpers(warmResult), helpers(only.compile("Main")));
		if (GeneratedProgramRunner.exitCode(warmResult) != 11)
			throw "the warm program changed behavior";
	}
}
