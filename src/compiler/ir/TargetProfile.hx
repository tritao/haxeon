package compiler.ir;

/** The targets the IR passes tell apart. C joins when one of its values first differs from HashLink's. */
enum TargetKind {
	HashLink;
	Wasm;
}

/**
 * What the IR generator and the IR passes need to know about the target, as one immutable value that is passed to them. A build
 * holds one; there is no ambient target state.
 */
final class TargetProfile {
	public final kind:TargetKind;

	/** The target stores a value class field inline in its parent and hands out a pointer into it (HashLink). */
	public final packedValueFields:Bool;

	function new(kind:TargetKind, packedValueFields:Bool) {
		this.kind = kind;
		this.packedValueFields = packedValueFields;
	}

	public static final hashLink = new TargetProfile(TargetKind.HashLink, true);
	public static final wasm = new TargetProfile(TargetKind.Wasm, false);

	/** Every value of the profile as comparable text (part of what a cached result depends on). */
	public function key():String
		return Std.string(kind) + ":packed=" + packedValueFields;
}
