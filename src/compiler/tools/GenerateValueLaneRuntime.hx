package compiler.tools;

import compiler.runtime.ValueLaneNativeSource;
import sys.io.File;

/** Keep native lane policy a checked product of the portable SSA definition. */
class GenerateValueLaneRuntime {
	static function main():Void {
		var args = Sys.args(), check = args.length == 2 && args[0] == "--check";
		if (!(check || args.length == 1)) throw "Usage: GenerateValueLaneRuntime [--check] output.h";
		var path = args[check ? 1 : 0], source = ValueLaneNativeSource.generate();
		if (check) {
			if (File.getContent(path) != source) throw 'Stale generated lane policy: $path';
		} else File.saveContent(path, source);
	}
}
