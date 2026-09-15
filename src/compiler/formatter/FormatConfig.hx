package compiler.formatter;

/** Canonical formatter configuration. */
typedef FormatConfig = {
	var lineWidth:Int;
	var indentWidth:Int;
	var continuationIndentWidth:Int;
	var useTabs:Bool;
}

class FormatConfigTools {
	public static function defaults(tabSize:Int, insertSpaces:Bool):FormatConfig
		return {
			lineWidth: 120,
			indentWidth: tabSize,
			continuationIndentWidth: tabSize,
			useTabs: !insertSpaces
		};

	public static function indentation(level:Int, config:FormatConfig):String {
		if (level <= 0)
			return "";
		var result = "";
		if (config.useTabs) {
			for (_ in 0...level)
				result += "\t";
		} else {
			var count = level * config.indentWidth;
			for (_ in 0...count)
				result += " ";
		}
		return result;
	}

	public static function continuationLevels(config:FormatConfig):Int {
		if (config.indentWidth <= 0)
			return 1;
		return Std.int(Math.max(1, Math.ceil(config.continuationIndentWidth / config.indentWidth)));
	}
}
