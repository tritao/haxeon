import compiler.ffi.CHeaderImporter;
import sys.io.File;

/** Standalone C-header to raw-HXI importer. */
class FfiImportMain {
	static function main():Void {
		var args = Sys.args(), target = "", output = "", library:Null<String> = null, includes:Array<String> = [], paths:Array<String> = [];
		for (arg in args)
			if (StringTools.startsWith(arg, "--target="))
				target = arg.substring(9);
			else if (StringTools.startsWith(arg, "--output="))
				output = arg.substring(9);
			else if (StringTools.startsWith(arg, "--include="))
				includes.push(arg.substring(10));
			else if (StringTools.startsWith(arg, "--library="))
				library = arg.substring(10);
			else if (StringTools.startsWith(arg, "--"))
				throw 'Unknown FFI import option "$arg"';
			else
				paths.push(arg);
		if (target.length == 0 || output.length == 0 || paths.length != 1)
			throw "Usage: haxeon-ffi-import --target=<triple> --output=<file> [--library=<name>] [--include=<dir>] <header>";
		File.saveContent(output, CHeaderImporter.importHeader(paths[0], target, includes, "clang", library));
		Sys.println('imported ${paths[0]} -> $output');
	}
}
