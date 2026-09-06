package compiler.ir;

/** Converts compiler storage names into names suitable for source-level debugging. */
class DebugNames {
	public static function sourceLocal(name:String):Null<String> {
		if (StringTools.startsWith(name, "$l")) {
			var separator = name.indexOf(":");
			return separator < 0 ? null : name.substr(separator + 1);
		}
		return StringTools.startsWith(name, "$") ? null : name;
	}
}
