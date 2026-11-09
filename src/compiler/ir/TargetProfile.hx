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

	/** HashLink stores value classes as headerless structs; Wasm represents them as ordinary references. */
	public final headerlessValueClasses:Bool;

	/** Native runtime dynamic objects for `{}` literals; otherwise they allocate `PlatformAbi.DYNAMIC_OBJECT_CLASS`. */
	public final dynamicObjectLiterals:Bool;

	/** Array accesses are checked by the generated code (the runtime natives do it elsewhere). */
	public final nativeArrayChecks:Bool;

	/** HashLink runtime natives that concatenate several strings with one allocation and format an Int without boxing it. */
	public final nativeStringFastPaths:Bool;

	/**
	 * Wasm: field reflection over object layouts is dispatched by the backend through a table keyed on the class id in every
	 * object's header, so the program carries one function per layout and no dispatcher of its own.
	 */
	public final nativeReflectionDispatch:Bool;

	function new(kind:TargetKind, packedValueFields:Bool, headerlessValueClasses:Bool, dynamicObjectLiterals:Bool, nativeArrayChecks:Bool,
			nativeStringFastPaths:Bool, nativeReflectionDispatch:Bool) {
		this.kind = kind;
		this.packedValueFields = packedValueFields;
		this.headerlessValueClasses = headerlessValueClasses;
		this.dynamicObjectLiterals = dynamicObjectLiterals;
		this.nativeArrayChecks = nativeArrayChecks;
		this.nativeStringFastPaths = nativeStringFastPaths;
		this.nativeReflectionDispatch = nativeReflectionDispatch;
	}

	public static final hashLink = new TargetProfile(TargetKind.HashLink, true, true, true, true, true, false);
	public static final wasm = new TargetProfile(TargetKind.Wasm, false, false, false, true, false, true);

	/** The portable IR `Frontend.compile` builds for tests that run no backend: HashLink's layout, with the runtime-specific fast paths off. */
	public static final portable = hashLink.withNativeArrayChecks(false).withNativeStringFastPaths(false);

	public function withNativeArrayChecks(enabled:Bool):TargetProfile
		return new TargetProfile(kind, packedValueFields, headerlessValueClasses, dynamicObjectLiterals, enabled, nativeStringFastPaths,
			nativeReflectionDispatch);

	public function withNativeStringFastPaths(enabled:Bool):TargetProfile
		return new TargetProfile(kind, packedValueFields, headerlessValueClasses, dynamicObjectLiterals, nativeArrayChecks, enabled, nativeReflectionDispatch);

	/** Every value of the profile as comparable text (part of what a cached result depends on). */
	public function key():String
		return Std.string(kind) + ":" + [
			packedValueFields,
			headerlessValueClasses,
			dynamicObjectLiterals,
			nativeArrayChecks,
			nativeStringFastPaths,
			nativeReflectionDispatch
		].map(flag -> flag ? "1" : "0").join("");
}
