package compiler.ir.codec;

import compiler.ir.model.IrFunction;
import compiler.query.Digest;

/**
 * The digest and equality of an IR function as a query value: of everything `IrFunctionStateCodec.encode` encodes, so a
 * field the codec carries is in the digest by construction, and two functions with equal digests encode the same.
 *
 * Encoding is expensive (see `docs/design/QUERY_ENGINE.md`, Digests): a pass's output is digested by its computation
 * (`QueryKind.computed`), and this is for an input that is new in a build, check mode and tests.
 */
class IrFunctionDigest {
	public static function feed(fn:IrFunction, digest:Digest):Void
		digest.bytes(IrFunctionStateCodec.encode(fn));

	public static function same(left:IrFunction, right:IrFunction):Bool
		return IrFunctionStateEquality.same(left, right);
}
