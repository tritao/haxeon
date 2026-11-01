package haxeon;

/** Compiler-generated copying, field masks and updates for types that declare Diffable. */
class Diff {
	public static function copy<T:Diffable>(value:T):T
		throw "Diff.copy must be lowered by the compiler";
}
