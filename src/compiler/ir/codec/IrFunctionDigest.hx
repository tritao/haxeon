package compiler.ir.codec;

import compiler.ir.IrFunction;
import compiler.query.Digest;

/**
 * The digest and equality of an IR function as a query value: of everything `IrFunctionStateCodec.encode` encodes, so a
 * field the codec carries is in the digest by construction, and two functions with equal digests encode the same.
 */
class IrFunctionDigest {
	public static function feed(fn:IrFunction, digest:Digest):Void
		digest.bytes(IrFunctionStateCodec.encode(fn));

	public static function same(left:IrFunction, right:IrFunction):Bool
		return IrFunctionStateEquality.same(left, right);
}
