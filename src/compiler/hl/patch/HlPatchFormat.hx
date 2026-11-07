package compiler.hl.patch;

/** Shared wire-format metadata for HashLink patch readers and writers. */
class HlPatchFormat {
	public static inline final MAGIC = "HLP";
	/** 11: virtual types carry stable nominal interface identities. */
	public static inline final VERSION:Int = 11;

	private function new() {}
}
