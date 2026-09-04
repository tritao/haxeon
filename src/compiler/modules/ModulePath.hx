package compiler.modules;

class ModulePath {
	public static function fromFile(path:String):String {
		var normalized = path.split("\\").join("/");
		var name = normalized.substring(normalized.lastIndexOf("/") + 1);
		return StringTools.endsWith(name, ".hx") ? name.substr(0, name.length - 3) : name;
	}
}
