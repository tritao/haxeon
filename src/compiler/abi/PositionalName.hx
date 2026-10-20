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
}
