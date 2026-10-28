package compiler.abi;

import compiler.semantic.LambdaName;

/**
 * Generated functions named by their position among their siblings: lambdas (`$lambda:<enclosing>:<member>#<ordinal>`, see
 * `LambdaName`) and function adapters (`$function-adapter:<context>:<ordinal>`). Such a name says where a function sits, not what
 * it is, so an edit that inserts, deletes or reorders siblings moves names onto other functions. The patch planner checks every
 * group of siblings for that (see `PatchPlanner.renumberedGroups`).
 */
class PositionalName {
	static inline final ADAPTER_PREFIX = "$function-adapter:";

	public static function is(name:String):Bool
		return LambdaName.is(name) || StringTools.startsWith(name, ADAPTER_PREFIX);

	/** The siblings of `name` share everything in their names but the ordinal. */
	public static function group(name:String):String
		return name.substring(0, separator(name));

	/** The position of `name` among its siblings. */
	public static function ordinal(name:String):Int
		return Std.parseInt(name.substring(separator(name) + 1));

	static function separator(name:String):Int
		return LambdaName.is(name) ? name.lastIndexOf("#") : name.lastIndexOf(":");

	/**
	 * `prints` (each function's own code fingerprint, `IrFunctionStateCodec.codeFingerprint`) with every lambda's fingerprint
	 * folded together with those of the lambdas written in it, in order, all the way down. A lambda's own code names the
	 * lambdas written in it without their ordinals, so on its own `() -> () -> 1` and `() -> () -> 2` look alike: their
	 * difference lives in the nested lambdas. Folded, two lambdas have the same fingerprint only when they and everything
	 * written in them run the same code.
	 */
	public static function nested(prints:Map<String, String>):Map<String, String> {
		var children:Map<String, Array<String>> = [];
		for (name in prints.keys()) {
			var outer = LambdaName.enclosing(name);
			if (outer == null || !prints.exists(outer))
				continue;
			var list = children.get(outer);
			if (list == null) {
				list = [];
				children.set(outer, list);
			}
			list.push(name);
		}
		var result:Map<String, String> = [];
		function fold(name:String):String {
			var known = result.get(name);
			if (known != null)
				return known;
			var own = prints.get(name), inner = children.get(name);
			if (inner == null) {
				result.set(name, own);
				return own;
			}
			inner.sort((a, b) -> {
				var left = group(a), right = group(b);
				return left != right ? Reflect.compare(compiler.ir.codec.IrTypeCodec.withoutOrdinals(left),
					compiler.ir.codec.IrTypeCodec.withoutOrdinals(right)) : ordinal(a) - ordinal(b);
			});
			var text = new StringBuf();
			text.add(own);
			for (child in inner) {
				text.add(";");
				text.add(compiler.ir.codec.IrTypeCodec.withoutOrdinals(group(child)));
				text.add("=");
				text.add(fold(child));
			}
			var print = haxe.crypto.Base64.encode(build.execution.ContentDigest.make(haxe.io.Bytes.ofString(text.toString())));
			result.set(name, print);
			return print;
		}
		for (name in prints.keys())
			fold(name);
		return result;
	}
}
