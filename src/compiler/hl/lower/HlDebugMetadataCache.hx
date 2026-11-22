package compiler.hl.lower;

import compiler.hl.HlCode.HlFunctionIdentity;
import compiler.ir.IrFunction;
import haxe.ds.ObjectMap;

/**
 * Immutable function identities memoized by persistent function identity. Entries live for one
 * generation: a lowering keeps only the fragments it used, so functions replaced by an edit are released
 * instead of accumulating in a long-lived compiler session.
 */
class HlDebugMetadataCache {
	var identities:ObjectMap<IrFunction, HlFunctionIdentity> = new ObjectMap();
	var nextIdentities:ObjectMap<IrFunction, HlFunctionIdentity> = new ObjectMap();

	public function new() {}

	public function identity(fn:IrFunction):Null<HlFunctionIdentity> {
		var value = nextIdentities.get(fn);
		if (value == null) {
			value = identities.get(fn);
			if (value != null)
				nextIdentities.set(fn, value);
		}
		return value;
	}

	public function rememberIdentity(fn:IrFunction, identity:HlFunctionIdentity):Void
		nextIdentities.set(fn, identity);

	var lastIdentities:Array<HlFunctionIdentity> = [];
	var lastPayload:Null<haxe.io.Bytes> = null;

	/** The function identities section's payload (`HlWriter.encodeFunctionIdentities`): the last one while the identities read the same. */
	public function identitiesPayload(identities:Array<HlFunctionIdentity>):haxe.io.Bytes {
		var payload = lastPayload;
		if (payload != null && sameIdentities(lastIdentities, identities))
			return payload;
		payload = compiler.hl.HlWriter.encodeFunctionIdentities(identities);
		lastIdentities = identities;
		lastPayload = payload;
		return payload;
	}

	static function sameIdentities(left:Array<HlFunctionIdentity>, right:Array<HlFunctionIdentity>):Bool {
		if (left.length != right.length)
			return false;
		for (index in 0...left.length) {
			var a = left[index], b = right[index];
			if (a != b
				&& (a.stableId != b.stableId || a.functionIndex != b.functionIndex || a.qualifiedName != b.qualifiedName
				|| a.displayName != b.displayName || a.sourcePath != b.sourcePath || a.start != b.start
				|| a.end != b.end
				|| a.line != b.line || a.flags != b.flags))
				return false;
		}
		return true;
	}

	/** Drops every fragment the finished lowering did not use. */
	public function endGeneration():Void {
		identities = nextIdentities;
		nextIdentities = new ObjectMap();
	}
}
