package build.execution;

import haxe.Json;
import haxe.crypto.Sha256;
import haxe.io.Bytes;
import haxe.io.Path;
import sys.FileSystem;
import sys.io.File;

private typedef StoredFingerprint = {
	final fingerprint:String;
}

/** Conservative project-local fingerprints for process actions. */
class ActionFingerprint {
	public static function compute(action:ExecutionAction, buildRoot:String, target:String, dependencies:Array<String>):String {
		var fields:Array<String> = ["action-v2", action.id.key(), target, action.description];
		switch action.action {
			case Process(command, arguments, cwd, environment):
				fields.push(command);
				fields.push('cwd:${Path.normalize(FileSystem.fullPath(cwd))}');
				var executable = resolveTool(command);
				fields.push('tool:$executable');
				if (FileSystem.exists(executable) && !FileSystem.isDirectory(executable))
					fields.push('tool-content:${Sha256.make(File.getBytes(executable)).toHex()}');
				for (argument in arguments)
					fields.push(argument);
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
						fields.push('inherited:$name=$value');
				}
				var keys = [for (key in environment.keys()) key];
				keys.sort(Reflect.compare);
				for (key in keys)
					fields.push('$key=${environment.get(key)}');
			case Compiler(_, _):
				fields.push("non-cacheable-compiler-action");
		}
		for (input in action.inputs) {
			fields.push('input:$input');
			appendPath(fields, input, new Map());
		}
		var orderedDependencies = dependencies.copy();
		orderedDependencies.sort(Reflect.compare);
		for (dependency in orderedDependencies)
			fields.push('dependency:$dependency');
		return Sha256.encode(Json.stringify(fields));
	}

	/** Portable identity for the global artifact cache; project-local paths are excluded. */
	public static function globalKey(action:ExecutionAction, target:String, dependencies:Array<String>):String {
		var fields:Array<String> = ["artifact-action-v2", action.id.key(), target, action.description];
		switch action.action {
			case Process(command, arguments, cwd, environment):
				fields.push('command:${Path.withoutDirectory(command)}');
				var executable = resolveTool(command);
				if (FileSystem.exists(executable) && !FileSystem.isDirectory(executable))
					fields.push('tool-content:${Sha256.make(File.getBytes(executable)).toHex()}');
				for (argument in arguments)
					fields.push('argument:${portableArgument(argument, action)}');
				var keys = [for (key in environment.keys()) key];
				keys.sort(Reflect.compare);
				for (key in keys)
					fields.push('environment:$key=${portableArgument(environment.get(key), action)}');
			case Compiler(_, _):
				fields.push("non-cacheable-compiler-action");
		}
		var inputIndex = 0;
		for (input in action.inputs) {
			fields.push('input:$inputIndex');
			appendPortablePath(fields, input, "");
			inputIndex++;
		}
		var orderedDependencies = dependencies.copy();
		orderedDependencies.sort(Reflect.compare);
		for (dependency in orderedDependencies)
			fields.push('dependency:$dependency');
		return Sha256.encode(Json.stringify(fields));
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

	static function appendPath(fields:Array<String>, path:String, visitedDirectories:Map<String, Bool>):Void {
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
			var entries = FileSystem.readDirectory(path);
			entries.sort(Reflect.compare);
			for (entry in entries) {
				var child = Path.join([path, entry]);
				fields.push('entry:$child');
				appendPath(fields, child, visitedDirectories);
			}
			return;
		}
		fields.push('file:$path');
		fields.push(Sha256.make(File.getBytes(path)).toHex());
	}

	static function appendPortablePath(fields:Array<String>, path:String, relative:String):Void {
		if (!FileSystem.exists(path)) {
			fields.push('missing:$relative');
			return;
		}
		if (FileSystem.isDirectory(path)) {
			fields.push('directory:$relative');
			var entries = FileSystem.readDirectory(path);
			entries.sort(Reflect.compare);
			for (entry in entries)
				appendPortablePath(fields, Path.join([path, entry]), Path.join([relative, entry]));
			return;
		}
		fields.push('file:$relative:${Sha256.make(File.getBytes(path)).toHex()}');
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
