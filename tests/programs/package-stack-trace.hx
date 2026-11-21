// A stack frame in a module of a package names the module's file by its path under the source root, as on HashLink.

import stackfiles.Thrower;

function main():Int {
	try {
		Thrower.fail(0);
	} catch (error:String) {
		for (item in haxe.CallStack.exceptionStack())
			switch item {
				case FilePos(_, file, line):
					var at = file.lastIndexOf("stackfiles/");
					Sys.println('${at < 0 ? file : file.substr(at)}:$line');
				default:
			}
	}
	return 42;
}
