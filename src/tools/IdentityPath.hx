package tools;

import sys.FileSystem;
import sys.io.File;

/**
 * `haxeon identity-path [build options] FROM TO`: why the code identity of module FROM depends on module TO. It builds the
 * project (to a scratch output, with a define that forces a compile) with `HAXEON_IDENTITY_GRAPH` set, so the compiler writes the
 * import graph its identities were made from, then prints the shortest import path and the size of FROM's identity closure.
 */
class IdentityPath {
	static final valueOptions = ["--project", "--target", "--build-mode", "--define", "--device", "--jobs"];

	public static function run(arguments:Array<String>, build:Array<String> -> Int):Int {
		var options = [], names = [], index = 0;
		while (index < arguments.length) {
			var argument = arguments[index++];
			if (StringTools.startsWith(argument, "--")) {
				options.push(argument);
				if (valueOptions.indexOf(argument) >= 0 && index < arguments.length)
					options.push(arguments[index++]);
			} else
				names.push(argument);
		}
		if (names.length != 2) {
			Sys.println("Usage: haxeon identity-path [--project PATH] FROM TO");
			return 2;
		}
		var scratch = (Sys.getEnv("TMPDIR") ?? "/tmp") + "/haxeon-identity-path-" + Sys.getEnv("USER") + "-" + Std.int(Sys.time());
		FileSystem.createDirectory(scratch);
		var graph = scratch + "/graph.txt";
		Sys.putEnv("HAXEON_IDENTITY_GRAPH", graph);
		var status = build(options.concat(["--output", scratch + "/identity.hl", "--define", "identity-graph=" + Std.int(Sys.time())]));
		if (status != 0)
			return status;
		if (!FileSystem.exists(graph)) {
			Sys.println("The program does not read code identities (haxeon.build.CodeIdentity), so no graph was made.");
			return 1;
		}
		var text = File.getContent(graph);
		FileSystem.deleteFile(graph);
		Sys.println(report(text, names[0], names[1]));
		return 0;
	}

	/** The report for `graph` (see `CodeIdentityTable.dumpGraph`). */
	public static function report(graph:String, from:String, to:String):String {
		var imports = new Map<String, Array<String>>();
		for (line in graph.split("\n")) {
			var parts = line.split("\t");
			if (parts.length < 2)
				continue;
			imports.set(parts[0], parts[1] == "" ? [] : parts[1].split(","));
		}
		if (!imports.exists(from))
			return 'Module "$from" is not in the program.';
		var parent = new Map<String, String>(), queue = [from];
		parent.set(from, "");
		var cursor = 0;
		while (cursor < queue.length) {
			var current = queue[cursor++];
			for (next in imports.get(current))
				if (!parent.exists(next) && imports.exists(next)) {
					parent.set(next, current);
					queue.push(next);
				}
		}
		var lines = ['The identity of $from covers ${queue.length} modules (itself included).'];
		if (!imports.exists(to))
			lines.push('Module "$to" is not in the program.');
		else if (!parent.exists(to))
			lines.push('Its identity does not depend on $to.');
		else {
			lines.push("Shortest import path (" + pathTo(parent, to).length + " edges):");
			for (edge in pathTo(parent, to))
				lines.push("  " + edge);
			// Every way in: the modules reachable from FROM that import TO directly, each with the edge that reaches it first.
			var importers = [for (name in queue) if (name != to && imports.get(name).indexOf(to) >= 0) name];
			importers.sort(Reflect.compare);
			lines.push('Reachable modules that import $to directly (${importers.length}):');
			for (importer in importers)
				lines.push("  " + (parent.get(importer) == "" ? "(the module itself)" : parent.get(importer) + " -> ") + importer + " -> " + to);
		}
		return lines.join("\n");
	}

	/** The edges "A -> B" of the path from the root to `to`, in order. */
	static function pathTo(parent:Map<String, String>, to:String):Array<String> {
		var edges = [], step = to;
		while (parent.get(step) != "") {
			edges.unshift(parent.get(step) + " -> " + step);
			step = parent.get(step);
		}
		return edges;
	}
}
