package tools.dev;

import build.execution.ContentDigest;
import haxe.io.Bytes;
import haxe.io.Path;
import sys.FileSystem;
import sys.io.File;
import sys.io.Process;

/** A Haxe entry point of this checkout to build to HashLink bytecode with the pinned stock Haxe. */
typedef ToolRequest = {
	/** The `-main` class, such as `compiler.tools.HaxeonCompiler`. */
	final main:String;

	/** Class paths added after the ones `common.hxml` lists, relative to the checkout or absolute. */
	final classPaths:Array<String>;

	/** `-D` values, as `NAME` or `NAME=VALUE`. */
	final defines:Array<String>;
}

/**
 * HashLink builds of this checkout's own entry points (the compiler, the build tool, the CLI, test mains), kept in `out/tools` under a
 * hash of everything the build reads: `common.hxml` and every file under its class paths and the extra ones, the pinned Haxe binary and
 * its standard library, and the request itself. A script asks for a tool by its main class and gets the same file until one of those
 * inputs changes, so no script builds its own temporary copy or hands a path to its children.
 *
 * Builds go to a temporary file renamed into place, so a reader never sees a partial one. Two callers that miss at once both build and
 * the second rename is dropped; scripts that start many children resolve their tools first. The newest builds of each main are kept,
 * and older ones are removed only once they are an hour old, so a run that resolved a path keeps finding it.
 */
class ToolArtifacts {
	/** Bump when the key's layout or the build command changes. */
	static inline final FORMAT = 1;

	static inline final KEEP_PER_MAIN = 3;
	static inline final PRUNE_AGE_SECONDS = 3600.0;

	final home:String;
	final directory:String;

	public function new(home:String) {
		this.home = Path.normalize(home);
		directory = Path.join([this.home, "out", "tools"]);
	}

	/** The path of an up-to-date build of `request`, building it first when there is none. Throws when the build fails. */
	public function resolve(request:ToolRequest):String {
		validateMain(request.main);
		var key = key(request).substr(0, 16),
			output = Path.join([directory, '${request.main}-$key.hl']);
		if (FileSystem.exists(output))
			return output;
		build(request, output);
		prune(request.main, output);
		return output;
	}

	/** The class paths `common.hxml` lists, in its order: the one list every stock-Haxe build of the compiler uses. */
	public function commonClassPaths():Array<String> {
		var result = [];
		for (line in File.getContent(Path.join([home, "common.hxml"])).split("\n")) {
			line = StringTools.trim(line);
			if (StringTools.startsWith(line, "-cp "))
				result.push(StringTools.trim(line.substr(4)));
		}
		if (result.length == 0)
			throw '${Path.join([home, "common.hxml"])} lists no class path';
		return result;
	}

	public function haxe():String {
		var path = Path.join([home, ".tools", "haxe", "haxe" + (Sys.systemName() == "Windows" ? ".exe" : "")]);
		if (!FileSystem.exists(path))
			throw 'Missing pinned Haxe compiler: $path; run scripts/bootstrap-tools.sh first';
		return path;
	}

	function key(request:ToolRequest):String {
		var text = new StringBuf();
		text.add('format $FORMAT\nmain ${request.main}\n');
		for (define in request.defines)
			text.add('define $define\n');
		text.add('haxe ${digestFile(haxe())}\n');
		text.add('common.hxml ${digestFile(Path.join([home, "common.hxml"]))}\n');
		var roots = commonClassPaths().concat(request.classPaths);
		roots.push(Path.join([".tools", "haxe", "std"]));
		for (root in roots) {
			var absolute = absolutePath(root);
			if (!FileSystem.exists(absolute) || !FileSystem.isDirectory(absolute))
				throw 'Class path is not a directory: $root';
			text.add('root $root\n');
			digestTree(absolute, "", text);
		}
		return ContentDigest.makeHex(Bytes.ofString(text.toString()));
	}

	/** Every file below `directory`, in a fixed order, as its relative path and content digest. */
	static function digestTree(directory:String, relative:String, into:StringBuf):Void {
		var entries = FileSystem.readDirectory(Path.join([directory, relative]));
		entries.sort(compareNames);
		for (entry in entries) {
			var child = relative == "" ? entry : relative + "/" + entry,
				path = Path.join([directory, child]);
			if (FileSystem.isDirectory(path))
				digestTree(directory, child, into);
			else
				into.add('$child ${digestFile(path)}\n');
		}
	}

	static function digestFile(path:String):String
		return ContentDigest.makeHex(File.getBytes(path));

	function build(request:ToolRequest, output:String):Void {
		ensureDirectory(directory);
		var temporary = Path.join([
			directory,
			'.${Path.withoutDirectory(output)}.${Std.int(Sys.time() * 1000) % 100000000}-${Std.random(1000000)}.hl'
		]), arguments = ["--cwd", home, "common.hxml"];
		for (classPath in request.classPaths)
			arguments = arguments.concat(["-cp", classPath]);
		for (define in request.defines)
			arguments = arguments.concat(["-D", define]);
		arguments = arguments.concat(["-main", request.main, "-hl", temporary]);
		var status = runForwardingToStderr(haxe(), arguments);
		if (status != 0 || !FileSystem.exists(temporary)) {
			removeQuietly(temporary);
			throw 'Building ${request.main} with the pinned Haxe failed (exit $status)';
		}
		if (FileSystem.exists(output)) // Another caller built the same inputs meanwhile; its file is equivalent.
			removeQuietly(temporary);
		else
			FileSystem.rename(temporary, output);
	}

	/** Runs a build whose output is diagnostics: both of its streams go to stderr, because stdout carries the resolved path. */
	static function runForwardingToStderr(command:String, arguments:Array<String>):Int {
		var process = new Process(command, arguments);
		#if (target.threaded && !eval)
		var done = new sys.thread.Lock();
		sys.thread.Thread.create(() -> {
			copyTo(process.stdout, Sys.stderr());
			done.release();
		});
		copyTo(process.stderr, Sys.stderr());
		done.wait();
		#else
		copyTo(process.stdout, Sys.stderr());
		copyTo(process.stderr, Sys.stderr());
		#end
		var status = process.exitCode();
		process.close();
		return status;
	}

	static function copyTo(input:haxe.io.Input, output:haxe.io.Output):Void {
		var buffer = Bytes.alloc(8192);
		try {
			while (true) {
				var count = input.readBytes(buffer, 0, buffer.length);
				if (count <= 0)
					break;
				output.writeBytes(buffer, 0, count);
				output.flush();
			}
		} catch (_:haxe.io.Eof) {}
	}

	/** Removes older builds of `main` beyond the newest few, and abandoned temporary files, once they are old enough. */
	function prune(main:String, keep:String):Void {
		var now = Sys.time(), builds:Array<{path:String, time:Float}> = [];
		for (entry in FileSystem.readDirectory(directory)) {
			var path = Path.join([directory, entry]),
				time = try FileSystem.stat(path).mtime.getTime() / 1000.0 catch (_:Dynamic) continue;
			if (StringTools.startsWith(entry, ".")) {
				if (now - time > PRUNE_AGE_SECONDS)
					removeQuietly(path);
			} else if (StringTools.startsWith(entry, main + "-")
				&& StringTools.endsWith(entry, ".hl")
				&& entry.length == main.length + 20
				&& path != keep)
				builds.push({path: path, time: time});
		}
		builds.sort((a, b) -> a.time > b.time ? -1 : a.time < b.time ? 1 : 0);
		for (index in 0...builds.length)
			if (index >= KEEP_PER_MAIN - 1 && now - builds[index].time > PRUNE_AGE_SECONDS)
				removeQuietly(builds[index].path);
	}

	function absolutePath(path:String):String
		return Path.normalize(Path.isAbsolute(path) ? path : Path.join([home, path]));

	static function validateMain(main:String):Void {
		if (!~/^[A-Za-z_][A-Za-z0-9_]*(\.[A-Za-z_][A-Za-z0-9_]*)*$/.match(main))
			throw 'Not a main class path: "$main"';
	}

	static function compareNames(a:String, b:String):Int
		return a < b ? -1 : a > b ? 1 : 0;

	static function ensureDirectory(path:String):Void {
		if (FileSystem.exists(path))
			return;
		ensureDirectory(Path.directory(path));
		try
			FileSystem.createDirectory(path)
		catch (_:Dynamic)
			if (!FileSystem.exists(path))
				throw 'Could not create $path';
	}

	static function removeQuietly(path:String):Void {
		try
			if (FileSystem.exists(path))
				FileSystem.deleteFile(path)
		catch (_:Dynamic) {}
	}
}
