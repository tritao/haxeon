package compiler.ir.hl;

import compiler.hl.HlCode.HlFunctionIdentity;
import compiler.hl.HlCode.HlOpcodeSourceSpan;
import compiler.hl.HlFunction;
import compiler.ir.IrFunction;
import haxe.ds.ObjectMap;

/** Immutable debugger metadata fragments memoized by persistent function identity. */
class HlDebugMetadataCache {
	final identities:ObjectMap<IrFunction, HlFunctionIdentity> = new ObjectMap();
	final spans:ObjectMap<HlFunction, Array<HlOpcodeSourceSpan>> = new ObjectMap();

	public function new() {}

	public function identity(fn:IrFunction):Null<HlFunctionIdentity>
		return identities.get(fn);

	public function rememberIdentity(fn:IrFunction, identity:HlFunctionIdentity):Void
		identities.set(fn, identity);

	public function functionSpans(fn:HlFunction):Null<Array<HlOpcodeSourceSpan>>
		return spans.get(fn);

	public function rememberFunctionSpans(fn:HlFunction, value:Array<HlOpcodeSourceSpan>):Void
		spans.set(fn, value);
}
