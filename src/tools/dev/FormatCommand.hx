package tools.dev;

import haxe.io.Path;
import sys.FileSystem;
import sys.io.File;
import sys.io.Process;

/**
 * `haxeon dev format [--check] [--changed]`: formats the Haxe sources of this checkout (src, tests, benchmarks), or checks
 * them with `--check`. `scripts/format.sh` runs it.
 *
 * Each file goes to the formatter its profile names (`scripts/format-source-profile.js`): `struct` files to `haxeon fmt`,
 * the rest to the external formatter (`scripts/format-external.js`), whose output the compiler-lexer token guard checks
 * before anything is written. Imports are sorted first (`haxeon lint --only import-order`) so the formatters see the final
 * order.
 *
 * With `--changed`, only the `.hx` files that differ from the merge base with origin/main, untracked ones included, and of
 * those only the ones that were clean at the base: until the one-shot reformat, a file that was already unformatted there
 * is left alone (imports are still sorted in every changed file).
 */
class FormatCommand {
	static final SOURCE_ROOTS = ["src", "tests", "benchmarks"];

	final home:String;
	final check:Bool;
	final work:String;
	var externalFormatter:Array<String> = [];

	function new(home:String, check:Bool, work:String) {
		this.home = home;
		this.check = check;
		this.work = work;
	}

	public static function run(arguments:Array<String>, home:String):Int {
		var check = false, changed = false;
		for (argument in arguments)
			switch argument {
				case "--check":
					check = true;
				case "--changed":
					changed = true;
				case _:
					Sys.stderr().writeString("Usage: haxeon dev format [--check] [--changed]\n");
					return 2;
			}
		if (!FileSystem.exists(Path.join([home, ".tools", "formatter", "run.js"]))) {
			Sys.stderr().writeString("missing local formatter; run ./scripts/bootstrap-tools.sh first\n");
			return 1;
		}
		var work = temporaryDirectory();
		try {
			var status = new FormatCommand(home, check, work).format(changed);
			removeTree(work);
			return status;
		} catch (error:Dynamic) {
			removeTree(work);
			throw error;
		}
	}

	function format(changed:Bool):Int {
		// Both formatter implementations use the compiler lexer. Never let the host tool write unchecked output, even when only
		// checking whether a file would change.
		var guard = Path.join([work, "token-guard.js"]);
		var built = Sys.command(Path.join([home, ".tools", "haxe", "haxe"]),
			["--cwd", home, "common.hxml", "-main", "tools.FormatterTokenGuard", "-js", guard]);
		if (built != 0)
			return built;
		externalFormatter = ["node", Path.join([home, "scripts", "format-external.js"]), guard];
		var orderFiles:Array<String>, sources:Array<String>;
		if (changed) {
			var changedFiles = changedSources();
			orderFiles = [for (relative in changedFiles) Path.join([home, relative])];
			var dirty = dirtyAtBase(changedFiles);
			sources = [
				for (relative in changedFiles)
					if (!dirty.exists(relative)) Path.join([home, relative])
			];
			if (sources.length == 0) {
				Sys.println("format: every changed .hx file was already unformatted at the merge base with origin/main (or none changed)");
				return importOrder(orderFiles);
			}
		} else {
			sources = [for (relative in trackedSources()) Path.join([home, relative])];
			orderFiles = sources.copy();
		}
		var structFiles = [], externalFiles = [];
		for (entry in profiles(sources))
			(entry.profile == "struct" ? structFiles : externalFiles).push(entry.path);
		var externalArguments = [];
		for (file in externalFiles) {
			externalArguments.push("-s");
			externalArguments.push(file);
		}
		if (check) {
			var status = 0;
			if (externalFiles.length > 0)
				status = worst(status, runExternal(externalArguments.concat(["--check"])));
			if (structFiles.length > 0)
				status = worst(status, haxeon(["fmt", "--check"].concat(structFiles)));
			return worst(status, importOrder(orderFiles));
		}
		var ordered = importOrder(orderFiles);
		if (ordered != 0)
			return ordered;
		if (externalFiles.length > 0) {
			// The formatter can need more than one pass to settle; three are enough, and a fourth would mean it does not.
			for (_ in 0...3) {
				runExternal(externalArguments);
				var settled = quiet(externalFormatter[0], externalFormatter.slice(1).concat(externalArguments).concat(["--check"]));
				if (settled.status > 1) {
					Sys.stderr().writeString(settled.output);
					return settled.status;
				}
				if (settled.status == 0)
					break;
			}
			if (quiet(externalFormatter[0], externalFormatter.slice(1).concat(externalArguments).concat(["--check"])).status != 0) {
				Sys.stderr().writeString("formatter did not reach a stable result after three passes\n");
				return 1;
			}
		}
		if (structFiles.length > 0) {
			var formatted = haxeon(["fmt"].concat(structFiles));
			return formatted != 0 ? formatted : haxeon(["fmt", "--check"].concat(structFiles));
		}
		return 0;
	}

	/** The `.hx` files under the source roots that differ from the merge base with origin/main, untracked ones included. */
	function changedSources():Array<String> {
		var base = StringTools.trim(capture("git", ["-C", home, "merge-base", "HEAD", "origin/main"]));
		var names = lines(capture("git",
			["-C", home, "diff", "--name-only", "--diff-filter=d", base, "--"].concat(SOURCE_ROOTS))).concat(lines(capture("git",
				["-C", home, "ls-files", "--others", "--exclude-standard", "--"].concat(SOURCE_ROOTS))));
		baseRevision = base;
		return sortedUnique([for (name in names) if (StringTools.endsWith(name, ".hx")) name]);
	}

	var baseRevision = "";

	/** The changed files that were not cleanly formatted at the merge base, by the same formatters the check uses. */
	function dirtyAtBase(changedFiles:Array<String>):Map<String, Bool> {
		var dirty:Map<String, Bool> = [], baseDirectory = Path.join([work, "base"]), baseFiles = [];
		for (relative in changedFiles) {
			if (quiet("git", ["-C", home, "cat-file", "-e", '$baseRevision:$relative']).status != 0)
				continue; // added since the base
			var shown = execute("git", ["-C", home, "show", '$baseRevision:$relative']);
			if (shown.status != 0)
				continue;
			var copy = Path.join([baseDirectory, relative]);
			FileSystem.createDirectory(Path.directory(copy));
			File.saveBytes(copy, shown.stdout);
			baseFiles.push(copy);
		}
		if (baseFiles.length == 0)
			return dirty;
		for (entry in profiles(baseFiles)) {
			var status = entry.profile == "struct" ? quiet(haxeonPath(),
				["fmt", "--check", entry.path]).status : quiet(externalFormatter[0], externalFormatter.slice(1).concat(["-s", entry.path, "--check"])).status;
			var relative = entry.path.substr(baseDirectory.length + 1);
			// A base version the formatter cannot format at all (its token guard refuses the output) was not formatted either: leave
			// the file alone like any other file that was unformatted at the base, and say so, instead of failing the whole check.
			if (status > 1)
				Sys.stderr().writeString('format: $relative cannot be formatted at the merge base; leaving it alone\n');
			if (status != 0)
				dirty.set(relative, true);
		}
		return dirty;
	}

	/** Every `.hx` file under the source roots that git tracks or would add (ignored files excluded, as `rg --files` did). */
	function trackedSources():Array<String> {
		var listed = lines(capture("git", ["-C", home, "ls-files", "--cached", "--others", "--exclude-standard", "--"].concat(SOURCE_ROOTS)));
		return sortedUnique([
			for (name in listed)
				if (StringTools.endsWith(name, ".hx") && FileSystem.exists(Path.join([home, name]))) name
		]);
	}

	/** Each file with the formatter profile `format-source-profile.js` gives it (`struct` or `external`). */
	function profiles(files:Array<String>):Array<{profile:String, path:String}> {
		var output = capture("node", [Path.join([home, "scripts", "format-source-profile.js"])].concat(files));
		return [
			for (line in lines(output)) {
				var tab = line.indexOf("\t");
				if (tab > 0) {profile: line.substr(0, tab), path: line.substr(tab + 1)};
			}
		];
	}

	function importOrder(files:Array<String>):Int {
		if (files.length == 0)
			return 0;
		if (check)
			return haxeon(["lint", "--only", "import-order"].concat(files));
		return quiet(haxeonPath(), ["lint", "--fix", "--only", "import-order"].concat(files)).status;
	}

	function runExternal(arguments:Array<String>):Int
		return Sys.command(externalFormatter[0], externalFormatter.slice(1).concat(arguments));

	function haxeon(arguments:Array<String>):Int
		return Sys.command(haxeonPath(), arguments);

	function haxeonPath():String
		return Path.join([home, "scripts", "haxeon"]);

	static function worst(a:Int, b:Int):Int
		return b > a ? b : a;

	static function lines(text:String):Array<String>
		return [
			for (line in text.split("\n"))
				if (StringTools.trim(line) != "") StringTools.trim(line)
		];

	static function sortedUnique(names:Array<String>):Array<String> {
		var seen:Map<String, Bool> = [], result = [];
		for (name in names)
			if (!seen.exists(name)) {
				seen.set(name, true);
				result.push(name);
			}
		result.sort(Reflect.compare);
		return result;
	}

	/** Runs `command`, returning its status and stdout; stderr passes through. */
	static function execute(command:String, arguments:Array<String>):{status:Int, stdout:haxe.io.Bytes} {
		var process = new Process(command, arguments);
		var output = process.stdout.readAll();
		var status = process.exitCode();
		process.close();
		return {status: status, stdout: output};
	}

	static function capture(command:String, arguments:Array<String>):String
		return execute(command, arguments).stdout.toString();

	/** Runs `command` with both streams collected instead of shown, for checks whose output only matters when they fail. */
	static function quiet(command:String, arguments:Array<String>):{status:Int, output:String} {
		var process = new Process(command, arguments),
			errors = new StringBuf();
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
		return {status: status, output: output + errors.toString()};
	}

	static function temporaryDirectory():String {
		var base = Sys.getEnv("TMPDIR");
		if (base == null || base == "")
			base = "/tmp";
		var directory = Path.join([base, 'haxeon-format.${Std.int(Sys.time() * 1000)}.${Std.random(1000000)}']);
		FileSystem.createDirectory(directory);
		return directory;
	}

	static function removeTree(path:String):Void {
		if (!FileSystem.exists(path))
			return;
		if (FileSystem.isDirectory(path)) {
			for (name in FileSystem.readDirectory(path))
				removeTree(Path.join([path, name]));
			FileSystem.deleteDirectory(path);
		} else
			FileSystem.deleteFile(path);
	}
}
