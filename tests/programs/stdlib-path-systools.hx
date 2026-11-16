import haxe.SysTools;
import haxe.io.Path;

// Path.withoutExtension and haxe.SysTools give Haxe's answers.
function main():Int {
	if (Path.withoutExtension("dir/file.tar.gz") != "dir/file.tar"
		|| Path.withoutExtension("dir.d/file") != "dir.d/file")
		return 1;
	if (Path.withoutExtension("a\\b.c") != "a\\b" || Path.withoutExtension(".") != "./"
		|| Path.withoutExtension("plain") != "plain")
		return 2;
	if (SysTools.quoteUnixArg("") != "''" || SysTools.quoteUnixArg("safe-name_1.txt") != "safe-name_1.txt")
		return 3;
	if (SysTools.quoteUnixArg("it's here") != "'it'\"'\"'s here'")
		return 4;
	if (SysTools.quoteWinArg("abc", false) != "abc" || SysTools.quoteWinArg("ab c", false) != '"ab c"')
		return 5;
	if (SysTools.quoteWinArg('a"b', false) != 'a\\"b' || SysTools.quoteWinArg("a&b", true) != "a^&b")
		return 6;
	return 42;
}
