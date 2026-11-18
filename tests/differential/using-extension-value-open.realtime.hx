// A generic extension read as a value whose type parameters the value does not fix: Haxe fixes them at the first call.
// Haxeon specializes a generic call when it types it, so it asks for the call instead (see LANGUAGE_SUPPORT.md).
using Lambda;

class Main {
	static function main():Void {
		var map = [1, 2].map;
		Sys.println(map(x -> x * 10));
	}
}
