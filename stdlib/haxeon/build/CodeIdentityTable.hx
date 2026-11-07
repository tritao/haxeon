package haxeon.build;

/**
 * The code identity of every module the program was built from. The compiler rewrites the text between the markers on each
 * build ("module<TAB>identity" lines, one per module), so the table is always as current as the program; the identities
 * themselves are made by `compiler.modules.CodeIdentityTable`. Read it through `CodeIdentity`.
 */
class CodeIdentityTable {
	public static final data:String = /*IDENTITY-BEGIN*/""/*IDENTITY-END*/;

	static var index:Null<Map<String, String>>;

	public static function lookup(name:String):Null<String> {
		var known = index;
		if (known == null) {
			known = [];
			for (line in data.split("\n")) {
				var tab = line.indexOf("\t");
				if (tab > 0)
					known.set(line.substr(0, tab), line.substr(tab + 1));
			}
			index = known;
		}
		return known.get(name);
	}
}
