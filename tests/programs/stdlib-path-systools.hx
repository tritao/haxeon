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
	if (Path.addTrailingSlash("a/b") != "a/b/" || Path.addTrailingSlash("a\\b") != "a\\b\\"
		|| Path.addTrailingSlash("") != "/"
		|| Path.addTrailingSlash("c/") != "c/")
		return 7;
	if (Path.removeTrailingSlashes("a/b//") != "a/b" || Path.removeTrailingSlashes("/") != "")
		return 8;
	if (Path.extension("dir.d/file.tar.gz") != "gz" || Path.extension("dir.d/file") != "" || Path.extension("..") != "")
		return 9;
	if (Path.withExtension("a/b.txt", "md") != "a/b.md" || Path.withExtension("a/b", "md") != "a/b.md")
		return 10;
	return 42;
}
