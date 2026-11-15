import compiler.Compiler;
import compiler.Diagnostic.CompileError;

/**
 * A type that an import of a whole module brings in only as a side effect cannot silently replace a type of the same name
 * that the current package declares: a use of that name is E1029, reported where it is used. Naming the import, declaring
 * the type in the module itself, or never using the name keeps the current behaviour.
 */
class ImportShadowingMain {
	static final NATIVE = "package native; enum abstract Kind(Int) to Int { var One = 1; } enum abstract Other(Int) to Int { var Two = 2; }";
	static final OWN = "package app; enum abstract Kind(Int) to Int { var One = 1; }";

	static function main():Void {
		// Used through the module import: ambiguous, at the use.
		rejected('package app; import native.Types; class User { public static function value():Int { var kind:Kind = Kind.One; return kind; } }', "User.hx",
			'Type name "Kind" is ambiguous: this package declares app.Kind');
		// Never used: no error, even with the module import.
		accepted('package app; import native.Types; class User { public static function value():Int return Other.Two; }');
		// Imported by name: a deliberate choice, which shadows as in Haxe.
		accepted('package app; import native.Types.Kind; class User { public static function value():Int return Kind.One; }');
		// Declared in the module itself: the module's own type wins, as in Haxe.
		accepted('package app; import native.Types; enum abstract Kind(Int) to Int { var One = 1; } class User { public static function value():Int return Kind.One; }',
			false);
		// A local variable that happens to share the name is not a type use.
		accepted('package app; import native.Types; class User { public static function value():Int { var Kind = 3; return Kind; } }');
		// A module imported under an alias is a namespace: its types are Native.Kind, and nothing comes in by its bare name.
		accepted('package app; import native.Types as Native; class User { public static function value():Int { var own:Kind = Kind.One; var native:Native.Kind = Native.Kind.One; return own + native; } }');
		rejectedAs('package app; import native.Types as Native; class User { public static function value():Int return Other.Two; }', "E1005");
		Sys.println("PASS: a whole-module import cannot silently shadow a same-package type, and an aliased module is a namespace");
	}

	static function compiler(user:String, withOwn:Bool = true):Compiler {
		var compiler = new Compiler();
		compiler.update("native/Types.hx", NATIVE);
		if (withOwn)
			compiler.update("app/Kind.hx", OWN);
		compiler.update("app/User.hx", user);
		compiler.update("Main.hx", "class Main { static function main():Int return app.User.value(); }");
		return compiler;
	}

	static function accepted(user:String, withOwn:Bool = true):Void
		compiler(user, withOwn).analyze("Main");

	static function rejectedAs(user:String, code:String):Void {
		var error:Null<CompileError> = null;
		try
			compiler(user).analyze("Main")
		catch (caught:CompileError)
			error = caught;
		if (error == null || error.diagnostic.code != code)
			throw 'Expected $code, got ${error == null ? "success" : error.diagnostic.code + " " + error.diagnostic.message}';
	}

	static function rejected(user:String, file:String, message:String):Void {
		var error:Null<CompileError> = null;
		try
			compiler(user).analyze("Main")
		catch (caught:CompileError)
			error = caught;
		if (error == null || error.diagnostic.code != "E1029" || error.diagnostic.message.indexOf(message) < 0)
			throw 'Expected E1029 "$message", got ${error == null ? "success" : error.diagnostic.code + " " + error.diagnostic.message}';
		var span = error.diagnostic.span;
		if (!StringTools.endsWith(span.file.path, file) || user.substring(span.start, span.end).indexOf("Kind") < 0)
			throw 'E1029 was not reported at a use of the name: ${span.file.path} ${span.start}..${span.end}';
	}
}
