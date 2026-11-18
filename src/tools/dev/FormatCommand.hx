package tools.dev;

import haxe.io.Path;
import sys.FileSystem;
import sys.io.Process;

/**
 * `haxeon dev format [--check] [--changed | --range FROM..TO]`: formats the Haxe sources of this checkout with `haxeon fmt`, after
 * `haxeon lint --fix` removes their unused imports and sorts the rest, or with `--check` reports what either would change. `scripts/format.sh`
 * runs it. The style is each project's "format" setting in haxeon.json; this tree uses the default (tabs, 120 columns). A
 * file that must keep its layout (a test that names its lines) says so with `@formatter:off` on its first line.
 *
 * Every `.hx` file git tracks or would add is formatted, vendored code aside; with `--changed`, only those that differ from
 * the merge base with origin/main; with `--range`, only those the commits in `FROM..TO` change, which is what the pre-push hook
 * (scripts/hooks/pre-push) checks. `--check` exits 1 when a file is not formatted, imports something it never uses or has its
 * imports out of order, and 2 when a file cannot be formatted.
 */
class FormatCommand {
	public static function run(arguments:Array<String>, home:String):Int {
		var check = false, changed = false, range:Null<String> = null, index = 0;
		while (index < arguments.length) {
			switch arguments[index] {
				case "--check":
					check = true;
				case "--changed":
					changed = true;
				case "--range" if (index + 1 < arguments.length && arguments[index + 1].indexOf("..") > 0):
					range = arguments[++index];
				case _:
					Sys.stderr().writeString("Usage: haxeon dev format [--check] [--changed | --range FROM..TO]\n");
					return 2;
			}
			index++;
		}
		var relatives = range != null ? rangeSources(home, range) : changed
			? changedSources(home) : trackedSources(home),
			files = [for (relative in relatives) Path.join([home, relative])];
		if (files.length == 0)
			return 0;
		var haxeon = Path.join([home, "scripts", "haxeon"]);
		if (check) {
			var ordered = batched(files,
				batch -> Sys.command(haxeon, ["lint"].concat(batch))),
				formatted = batched(files, batch -> Sys.command(haxeon, ["fmt", "--check"].concat(batch)));
			return formatted > ordered ? formatted : ordered;
		}
		// Imports first, so the formatter lays out what remains of them in their final order.
		var ordered = batched(files, batch -> quiet(haxeon, ["lint", "--fix"].concat(batch)));
		return ordered != 0 ? ordered : batched(files, batch -> Sys.command(haxeon, ["fmt"].concat(batch)));
	}

	/**
	 * Runs `command` over the files a batch at a time and returns the worst status. A command line goes to the shell as one
	 * argument, which Linux caps at 128 KB, and the whole tree's paths are longer than that.
	 */
	static function batched(files:Array<String>, command:Array<String>->Int):Int {
		var worst = 0, index = 0;
		while (index < files.length) {
			var status = command(files.slice(index, index + BATCH));
			if (status > worst)
				worst = status;
			index += BATCH;
		}
		return worst;
	}

	static inline final BATCH = 400;

	/** Every `.hx` file git tracks or would add, outside vendored code. */
	static function trackedSources(home:String):Array<String>
		return haxeSources(home, lines(capture("git", [
			"-C",
			home,
			"ls-files",
			"--cached",
			"--others",
			"--exclude-standard"
		])));

	/** The `.hx` files that differ from the merge base with origin/main, untracked ones included. */
	static function changedSources(home:String):Array<String> {
		var base = StringTools.trim(capture("git", ["-C", home, "merge-base", "HEAD", "origin/main"]));
		return haxeSources(home,
			lines(capture("git", ["-C", home, "diff", "--name-only", "--diff-filter=d", base]))
			.concat(lines(capture("git", [
				"-C",
				home,
				"ls-files",
				"--others",
				"--exclude-standard"
			]))));
	}

	/** The `.hx` files the commits in `range` (`FROM..TO`) change, deletions aside. */
	static function rangeSources(home:String, range:String):Array<String>
		return haxeSources(home, lines(capture("git", ["-C", home, "diff", "--name-only", "--diff-filter=d", range])));

	static function haxeSources(home:String, names:Array<String>):Array<String> {
		var seen:Map<String, Bool> = [], result = [];
		for (name in names)
			if (StringTools.endsWith(name, ".hx") && !isVendored(name) && !seen.exists(name)
				&& FileSystem.exists(Path.join([
					home,
					name
				]))) {
				seen.set(name, true);
				result.push(name);
			}
		result.sort(Reflect.compare);
		return result;
	}

	static function isVendored(name:String):Bool
		return StringTools.startsWith(name, "vendor/") || name.indexOf("/vendor/") >= 0;

	static function lines(text:String):Array<String>
		return [for (line in text.split("\n")) if (StringTools.trim(line) != "") StringTools.trim(line)];

	static function capture(command:String, arguments:Array<String>):String {
		var process = new Process(command, arguments);
		var output = process.stdout.readAll().toString();
		process.exitCode();
		process.close();
		return output;
	}

	/** Runs `command` without showing its output unless it fails. */
	static function quiet(command:String, arguments:Array<String>):Int {
		var process = new Process(command, arguments), errors = new StringBuf();
		// Both streams are drained at once, so neither fills its pipe while the other is read.
		#if (target.threaded && !eval)
		var done = new sys.thread.Lock();
		sys.thread.Thread.create(() -> {
			errors.add(process.stderr.readAll().toString());
			done.release();
		});
		var output = process.stdout.readAll().toString();
		done.wait();
		#else
		var output = process.stdout.readAll().toString();
		errors.add(process.stderr.readAll().toString());
		#end
		var status = process.exitCode();
		process.close();
		if (status != 0)
			Sys.stderr().writeString(output + errors.toString());
		return status;
	}
}
