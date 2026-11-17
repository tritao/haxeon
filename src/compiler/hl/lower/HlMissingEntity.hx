package compiler.hl.lower;

/** Lowering found that an object type or field the function leans on is not in the program: the function's IR is stale (see `HlLower`). */
class HlMissingEntity extends haxe.Exception {
	public function new(message:String)
		super(message);
}
