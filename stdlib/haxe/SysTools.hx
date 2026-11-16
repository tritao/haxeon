package haxe;

import haxe.ds.ReadOnlyArray;

/** Quoting of command line arguments, as in Haxe's standard library. */
class SysTools {
	/** Character codes of the characters that will be escaped by `quoteWinArg(_, true)`. */
	public static final winMetaCharacters:ReadOnlyArray<Int> = [
		" ".code, "(".code, ")".code, "%".code, "!".code, "^".code, "\"".code, "<".code, ">".code, "&".code, "|".code,
		"\n".code, "\r".code, ",".code, ";".code
	];

	/** `argument` as a single command line argument on Unix: quoted, or escaped if necessary. */
	public static function quoteUnixArg(argument:String):String {
		// Based on cpython's shlex.quote().
		if (argument == "")
			return "''";
		if (!~/[^a-zA-Z0-9_@%+=:,.\/-]/.match(argument))
			return argument;
		// Single quotes, with single quotes inside put into double quotes: $'b becomes '$'"'"'b'.
		return "'" + StringTools.replace(argument, "'", "'\"'\"'") + "'";
	}

	/**
	 * `argument` as a single command line argument on Windows, by the rules of
	 * http://msdn.microsoft.com/en-us/library/ms880421; with `escapeMetaCharacters`, cmd.exe's meta characters are escaped with "^".
	 */
	public static function quoteWinArg(argument:String, escapeMetaCharacters:Bool):String {
		// Unless there is no space, tab, slash, backslash or double quote and it is not empty. Based on cpython's subprocess.list2cmdline().
		if (!~/^(\/)?[^ \t\/\\"]+$/.match(argument)) {
			var result = new StringBuf();
			var needquote = argument.indexOf(" ") != -1 || argument.indexOf("\t") != -1 || argument == ""
				|| argument.indexOf("/") > 0;
			if (needquote)
				result.add('"');
			var backslashes = new StringBuf();
			for (i in 0...argument.length) {
				var code = StringTools.fastCodeAt(argument, i);
				if (code == "\\".code) {
					// Whether they double is known at the next character.
					backslashes.add("\\");
				} else if (code == '"'.code) {
					var run = backslashes.toString();
					result.add(run);
					result.add(run);
					backslashes = new StringBuf();
					result.add('\\"');
				} else {
					if (backslashes.length > 0) {
						result.add(backslashes.toString());
						backslashes = new StringBuf();
					}
					result.addChar(code);
				}
			}
			result.add(backslashes.toString());
			if (needquote) {
				result.add(backslashes.toString());
				result.add('"');
			}
			argument = result.toString();
		}
		if (!escapeMetaCharacters)
			return argument;
		var result = new StringBuf();
		for (i in 0...argument.length) {
			var code = StringTools.fastCodeAt(argument, i);
			if (winMetaCharacters.indexOf(code) >= 0)
				result.addChar("^".code);
			result.addChar(code);
		}
		return result.toString();
	}
}
