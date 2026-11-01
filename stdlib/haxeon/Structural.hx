package haxeon;

/** Compiler intrinsic that copies the stored fields of a mutable Diffable class. */
class Structural {
	public static function copy<T:Diffable>(value:T):T
		throw "Structural.copy must be lowered by the compiler";
}
