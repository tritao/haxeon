package compiler.ir.hl;

import compiler.hl.HlCode.HlFunctionIdentity;
import compiler.hl.HlCode.HlOpcodeSourceSpan;
import compiler.hl.HlFunction;
import compiler.ir.IrFunction;
import haxe.ds.ObjectMap;

/**
 * Immutable debugger metadata fragments memoized by persistent function identity. Entries live for one
 * generation: a lowering keeps only the fragments it used, so functions replaced by an edit are released
 * instead of accumulating in a long-lived compiler session.
 */
class HlDebugMetadataCache {
	var identities:ObjectMap<IrFunction, HlFunctionIdentity> = new ObjectMap();
	var spans:ObjectMap<HlFunction, Array<HlOpcodeSourceSpan>> = new ObjectMap();
	var nextIdentities:ObjectMap<IrFunction, HlFunctionIdentity> = new ObjectMap();
	var nextSpans:ObjectMap<HlFunction, Array<HlOpcodeSourceSpan>> = new ObjectMap();

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

	public function functionSpans(fn:HlFunction):Null<Array<HlOpcodeSourceSpan>> {
		var value = nextSpans.get(fn);
		if (value == null) {
			value = spans.get(fn);
			if (value != null)
				nextSpans.set(fn, value);
		}
		return value;
	}

	public function rememberFunctionSpans(fn:HlFunction, value:Array<HlOpcodeSourceSpan>):Void
		nextSpans.set(fn, value);

	/** Drops every fragment the finished lowering did not use. */
	public function endGeneration():Void {
		identities = nextIdentities;
		spans = nextSpans;
		nextIdentities = new ObjectMap();
		nextSpans = new ObjectMap();
	}
}
