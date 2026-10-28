package compiler.hl.patch;

/** Shared wire-format metadata for HashLink patch readers and writers. */
class HlPatchFormat {
	public static inline final MAGIC = "HLP";
	/** 10: patches append object, struct, virtual and packed types, and the null value globals of new object types. */
	public static inline final VERSION:Int = 10;

	private function new() {}
}
