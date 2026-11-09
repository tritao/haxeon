package compiler.ir.hl;

/** Lowering found that an object type or field the function leans on is not in the program: the function's IR is stale (see `HlLower`). */
final class HlMissingEntity {
	public final message:String;

	public function new(message:String)
		this.message = message;

	public function toString():String
		return message;
}
