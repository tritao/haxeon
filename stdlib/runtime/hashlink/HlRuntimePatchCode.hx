package runtime.hashlink;

/** Owns one externally retained HashLink patch-code allocation. */
class HlRuntimePatchCode {
	/** Immutable patch revision carried by the native allocation. */
	public final revision:Int;

	final module:HlRuntimeModule;
	var code:Null<hl.Abstract<"realtime_jit_code">>;
	var released:Bool = false;

	public function new(module:HlRuntimeModule, publication:HlRuntimePatchPublication) {
		if (module == null || publication == null || publication.status != 0 || publication.code == null)
			throw "HashLink patch-code ownership requires a successful native publication";
		this.module = module;
		code = publication.code;
		revision = module.codeRevision(code);
		if (revision < 0)
			throw "HashLink patch-code publication has no valid revision";
	}

	/** Whether the native allocation has already been released. */
	public inline function isReleased():Bool
		return released;

	/** Release the native allocation exactly once. */
	public function release():Bool {
		if (released)
			return true;
		if (!module.releaseCode(code))
			return false;
		code = null;
		released = true;
		return true;
	}
}
