package compiler.modules;

class ModulePath {
	public static function fromFile(path:String):String {
		var normalized = path.split("\\").join("/");
		while (StringTools.startsWith(normalized, "./"))
			normalized = normalized.substr(2);
		if (StringTools.endsWith(normalized, ".hx"))
			normalized = normalized.substr(0, normalized.length - 3);
		return normalized.split("/").filter(function(part) return part.length > 0).join(".");
	}
}
