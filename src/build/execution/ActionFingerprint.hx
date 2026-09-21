package build.execution;

import haxe.Json;
import haxe.crypto.Sha256;
import haxe.io.Path;
import sys.FileSystem;
import sys.io.File;

private typedef StoredFingerprint = {
	final fingerprint:String;
}

private class FingerprintFields {
	final buffer:StringBuf = new StringBuf();

	public function new() {}

	public function add(value:String):Void {
		buffer.add(value.length);
		buffer.add(":");
		buffer.add(value);
		buffer.add("\n");
	}

	public inline function push(value:String):Void
		add(value);

	public function digest():String
		return Sha256.encode(buffer.toString());
}

/** Conservative project-local fingerprints for process actions. */
class ActionFingerprint {
	public static function compute(action:ExecutionAction, buildRoot:String, target:String, dependencies:Array<String>):String {
		var fields = new FingerprintFields();
		fields.add("action-v3");
		fields.add(action.id.key());
		fields.add(target);
		fields.add(action.description);
		switch action.action {
			case Process(command, arguments, cwd, environment):
				appendCommand(fields, command, arguments, cwd, environment, false);
			case Compiler(command, arguments, cwd, environment, _):
				appendCommand(fields, command, arguments, cwd, environment, false);
		}
		for (input in action.inputs) {
			fields.add('input:$input');
			appendPath(fields, input, new Map(), buildRoot, false);
		}
		var orderedDependencies = dependencies.copy();
		orderedDependencies.sort(Reflect.compare);
		for (dependency in orderedDependencies)
			fields.push('dependency:$dependency');
		return fields.digest();
	}

	/** Portable identity for the global artifact cache; project-local paths are excluded. */
	public static function globalKey(action:ExecutionAction, target:String, dependencies:Array<String>):String {
		var fields = new FingerprintFields();
		fields.add("artifact-action-v3");
		fields.add(action.id.key());
		fields.add(target);
		fields.add(action.description);
		switch action.action {
			case Process(command, arguments, cwd, environment):
				appendPortableCommand(fields, command, arguments, environment, action);
			case Compiler(command, arguments, _, environment, _):
				appendPortableCommand(fields, command, arguments, environment, action);
		}
		var inputIndex = 0;
		for (input in action.inputs) {
			fields.push('input:$inputIndex');
			appendPortablePath(fields, input, "", new Map());
			inputIndex++;
		}
		var orderedDependencies = dependencies.copy();
		orderedDependencies.sort(Reflect.compare);
		for (dependency in orderedDependencies)
			fields.push('dependency:$dependency');
		return fields.digest();
	}

	public static function load(buildRoot:String, action:ExecutionAction):Null<String> {
		var path = recordPath(buildRoot, action);
		if (!FileSystem.exists(path))
			return null;
		try {
			var stored:StoredFingerprint = cast Json.parse(File.getContent(path));
			return stored.fingerprint;
		} catch (_:Dynamic) {
			return null;
		}
	}

	public static function save(buildRoot:String, action:ExecutionAction, fingerprint:String):Void {
		var path = recordPath(buildRoot, action),
			directory = Path.directory(path);
		ensureDirectory(directory);
		File.saveContent(path, Json.stringify({fingerprint: fingerprint}) + "\n");
	}

	public static function outputsExist(action:ExecutionAction):Bool {
		if (action.outputs.length == 0)
			return false;
		for (output in action.outputs)
			if (!FileSystem.exists(output))
				return false;
		return true;
	}

	static function recordPath(buildRoot:String, action:ExecutionAction):String
		return Path.join([buildRoot, ".haxeon", "actions", Sha256.encode(action.id.key()) + ".json"]);

	static function appendPath(fields:FingerprintFields, path:String, visitedDirectories:Map<String, Bool>, buildRoot:String, strong:Bool):Void {
		if (!FileSystem.exists(path)) {
			fields.push('missing:$path');
			return;
		}
		if (FileSystem.isDirectory(path)) {
			fields.push('directory:$path');
			var canonicalDirectory = Path.normalize(FileSystem.fullPath(path));
			if (visitedDirectories.exists(canonicalDirectory)) {
				fields.push('directory-cycle:$canonicalDirectory');
				return;
			}
			visitedDirectories.set(canonicalDirectory, true);
			appendGitIdentity(fields, path);
			var entries = FileSystem.readDirectory(path);
			entries.sort(Reflect.compare);
			for (entry in entries) {
				var child = Path.join([path, entry]);
				if (ignoredDirectoryEntry(entry, child, buildRoot)) {
					fields.add('ignored:$entry');
					continue;
				}
				fields.push('entry:$child');
				appendPath(fields, child, visitedDirectories, buildRoot, strong);
			}
			return;
		}
		fields.push('file:$path');
		fields.push(fileIdentity(path, strong));
	}

	static function appendPortablePath(fields:FingerprintFields, path:String, relative:String, visitedDirectories:Map<String, Bool>):Void {
		if (!FileSystem.exists(path)) {
			fields.push('missing:$relative');
			return;
		}
		if (FileSystem.isDirectory(path)) {
			fields.push('directory:$relative');
			var canonicalDirectory = Path.normalize(FileSystem.fullPath(path));
			if (visitedDirectories.exists(canonicalDirectory)) {
				fields.add('directory-cycle:$relative');
				return;
			}
			visitedDirectories.set(canonicalDirectory, true);
			appendGitIdentity(fields, path);
			var entries = FileSystem.readDirectory(path);
			entries.sort(Reflect.compare);
			for (entry in entries) {
				var child = Path.join([path, entry]);
				if (ignoredDirectoryEntry(entry, child, "")) {
					fields.add('ignored:$entry');
					continue;
				}
				appendPortablePath(fields, child, Path.join([relative, entry]), visitedDirectories);
			}
			return;
		}
		fields.push('file:$relative:${Sha256.make(File.getBytes(path)).toHex()}');
	}

	static function fileIdentity(path:String, strong:Bool):String {
		if (strong)
			return Sha256.make(File.getBytes(path)).toHex();
		var stat = FileSystem.stat(path);
		return '${stat.size}:${stat.mtime.getTime()}';
	}

	static function appendCommand(fields:FingerprintFields, command:String, arguments:Array<String>, cwd:String, environment:Map<String, String>,
			strong:Bool):Void {
		fields.add('command:$command');
		fields.add('cwd:${Path.normalize(FileSystem.fullPath(cwd))}');
		var executable = resolveTool(command);
		fields.add('tool:$executable');
		if (FileSystem.exists(executable) && !FileSystem.isDirectory(executable))
			fields.add('tool-content:${fileIdentity(executable, strong)}');
		for (argument in arguments)
			fields.add('argument:$argument');
		for (name in [
			"PATH",
			"CC",
			"CXX",
			"AR",
			"CFLAGS",
			"CPPFLAGS",
			"LDFLAGS",
			"CPATH",
			"C_INCLUDE_PATH",
			"LIBRARY_PATH",
			"INCLUDE",
			"LIB",
			"LIBPATH",
			"SDKROOT",
			"MACOSX_DEPLOYMENT_TARGET"
		]) {
			var value = Sys.getEnv(name);
			if (value != null)
				fields.add('inherited:$name=$value');
		}
		var keys = [for (key in environment.keys()) key];
		keys.sort(Reflect.compare);
		for (key in keys)
			fields.add('environment:$key=${environment.get(key)}');
	}

	static function appendPortableCommand(fields:FingerprintFields, command:String, arguments:Array<String>, environment:Map<String, String>,
			action:ExecutionAction):Void {
		fields.add('command:${Path.withoutDirectory(command)}');
		var executable = resolveTool(command);
		if (FileSystem.exists(executable) && !FileSystem.isDirectory(executable))
			fields.add('tool-content:${fileIdentity(executable, true)}');
		for (argument in arguments)
			fields.add('argument:${portableArgument(argument, action)}');
		var keys = [for (key in environment.keys()) key];
		keys.sort(Reflect.compare);
		for (key in keys)
			fields.add('environment:$key=${portableArgument(environment.get(key), action)}');
	}

	static function ignoredDirectoryEntry(name:String, path:String, buildRoot:String):Bool {
		if (!FileSystem.isDirectory(path))
			return name == ".git";
		if (name == ".git" || name == ".tools" || name == "build" || name == "out" || StringTools.startsWith(name, "cmake-build-"))
			return true;
		if (buildRoot == null || buildRoot.length == 0)
			return false;
		if (!FileSystem.exists(buildRoot))
			return false;
		return Path.normalize(FileSystem.fullPath(path)) == Path.normalize(FileSystem.fullPath(buildRoot));
	}

	static function appendGitIdentity(fields:FingerprintFields, directory:String):Void {
		var marker = Path.join([directory, ".git"]);
		if (!FileSystem.exists(marker))
			return;
		try {
			var gitDirectory = marker;
			if (!FileSystem.isDirectory(marker)) {
				var markerContent = StringTools.trim(File.getContent(marker));
				if (!StringTools.startsWith(markerContent, "gitdir:"))
					return;
				var configured = StringTools.trim(markerContent.substr(7));
				gitDirectory = Path.normalize(Path.isAbsolute(configured) ? configured : Path.join([directory, configured]));
			}
			var headPath = Path.join([gitDirectory, "HEAD"]);
			if (!FileSystem.exists(headPath))
				return;
			var head = StringTools.trim(File.getContent(headPath)),
				revision = head;
			if (StringTools.startsWith(head, "ref:")) {
				var reference = StringTools.trim(head.substr(4)),
					referencePath = Path.join([gitDirectory, reference]);
				if (FileSystem.exists(referencePath))
					revision = StringTools.trim(File.getContent(referencePath));
				else {
					var packed = Path.join([gitDirectory, "packed-refs"]);
					if (FileSystem.exists(packed))
						for (line in File.getContent(packed).split("\n"))
							if (!StringTools.startsWith(line, "#")
								&& !StringTools.startsWith(line, "^")
								&& StringTools.endsWith(line, ' $reference')) {
								revision = line.substr(0, line.indexOf(" "));
								break;
							}
				}
			}
			fields.add('git:$revision');
		} catch (_:Dynamic) {}
	}

	static function portableArgument(argument:String, action:ExecutionAction):String {
		var result = argument;
		for (output in action.outputs)
			result = StringTools.replace(result, output, "<output>");
		for (input in action.inputs)
			result = StringTools.replace(result, input, "<input>");
		if (Path.isAbsolute(result))
			return "<path>";
		return result;
	}

	static function resolveTool(command:String):String {
		if (Path.isAbsolute(command) || command.indexOf("/") >= 0 || command.indexOf("\\") >= 0)
			return FileSystem.exists(command) ? FileSystem.fullPath(command) : command;
		var path = Sys.getEnv("PATH");
		if (path == null)
			return command;
		var suffixes = Sys.systemName() == "Windows" ? [""].concat((Sys.getEnv("PATHEXT") == null ? ".COM;.EXE;.BAT;.CMD" : Sys.getEnv("PATHEXT"))
			.split(";")) : [""];
		for (directory in path.split(Sys.systemName() == "Windows" ? ";" : ":"))
			for (suffix in suffixes) {
				var candidate = Path.join([directory, command + suffix]);
				if (FileSystem.exists(candidate) && !FileSystem.isDirectory(candidate))
					return FileSystem.fullPath(candidate);
			}
		return command;
	}

	static function ensureDirectory(path:String):Void {
		if (path == null || path == "" || path == "." || FileSystem.exists(path))
			return;
		var parent = Path.directory(path);
		if (parent != path && parent != "")
			ensureDirectory(parent);
		if (!FileSystem.exists(path))
			FileSystem.createDirectory(path);
	}
}
