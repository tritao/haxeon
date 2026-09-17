package build.execution;

import haxe.Json;
import haxe.crypto.Sha256;
import haxe.io.Path;
import sys.FileSystem;
import sys.io.File;

private typedef CachedOutput = {
	final file:String;
	final checksum:String;
	final mode:Int;
}

private typedef CachedManifest = {
	final version:Int;
	final outputs:Array<CachedOutput>;
}

/** Shared cache for complete, validated process-action outputs. */
class ArtifactCache {
	final cacheRoot:String;

	public function new() {
		var cacheOverride = Sys.getEnv("HAXEON_ARTIFACT_CACHE");
		if (cacheOverride != null && cacheOverride.length > 0)
			cacheRoot = Path.normalize(cacheOverride);
		else {
			var home = Sys.systemName() == "Windows" ? Sys.getEnv("USERPROFILE") : Sys.getEnv("HOME");
			if (home == null || home.length == 0)
				home = Sys.getCwd();
			cacheRoot = Path.join([home, ".haxeon", "cache", "artifacts"]);
		}
	}

	public function restore(action:ExecutionAction, key:String):Bool {
		if (!isShareable(action))
			return false;
		var directory = Path.join([cacheRoot, key]),
			manifestPath = Path.join([directory, "manifest.json"]);
		if (!FileSystem.exists(manifestPath))
			return false;
		var manifest:CachedManifest;
		try {
			manifest = cast Json.parse(File.getContent(manifestPath));
		} catch (_:Dynamic) {
			return false;
		}
		if (manifest.version != 2 || manifest.outputs == null || manifest.outputs.length != action.outputs.length)
			return false;
		var temporary:Array<String> = [];
		try {
			for (index in 0...action.outputs.length) {
				var cached = manifest.outputs[index],
					source = Path.join([directory, cached.file]);
				if (!FileSystem.exists(source)
					|| FileSystem.isDirectory(source)
					|| Sha256.make(File.getBytes(source)).toHex() != cached.checksum)
					throw "invalid cached output";
				var temp = action.outputs[index] + '.haxeon-cache-${Std.int(Date.now().getTime())}-$index';
				ensureDirectory(Path.directory(temp));
				File.copy(source, temp);
				temporary.push(temp);
			}
			for (index in 0...action.outputs.length) {
				var output = action.outputs[index];
				if (FileSystem.exists(output))
					if (FileSystem.isDirectory(output))
						throw "cannot replace directory output";
					else
						FileSystem.deleteFile(output);
				FileSystem.rename(temporary[index], output);
				applyMode(output, manifest.outputs[index].mode);
			}
			return true;
		} catch (_:Dynamic) {
			for (temp in temporary)
				if (FileSystem.exists(temp))
					FileSystem.deleteFile(temp);
			return false;
		}
	}

	public function publish(action:ExecutionAction, key:String):Void {
		if (!isShareable(action) || !outputsExist(action))
			return;
		var directory = Path.join([cacheRoot, key]),
			manifestPath = Path.join([directory, "manifest.json"]);
		if (FileSystem.exists(manifestPath))
			return;
		var temporary = Path.join([cacheRoot, '.artifact-${key}-${Std.int(Date.now().getTime())}']);
		try {
			ensureDirectory(temporary);
			var outputs:Array<CachedOutput> = [];
			for (index in 0...action.outputs.length) {
				var output = action.outputs[index],
					cachedFile = 'output-$index',
					destination = Path.join([temporary, cachedFile]);
				File.copy(output, destination);
				outputs.push({file: cachedFile, checksum: Sha256.make(File.getBytes(destination)).toHex(), mode: FileSystem.stat(output).mode & 0x1ff});
			}
			File.saveContent(Path.join([temporary, "manifest.json"]), Json.stringify({version: 2, outputs: outputs}) + "\n");
			ensureDirectory(cacheRoot);
			if (!FileSystem.exists(directory))
				FileSystem.rename(temporary, directory);
			else
				removeTree(temporary);
		} catch (_:Dynamic) {
			if (FileSystem.exists(temporary))
				removeTree(temporary);
		}
	}

	static function outputsExist(action:ExecutionAction):Bool {
		for (output in action.outputs)
			if (!FileSystem.exists(output) || FileSystem.isDirectory(output))
				return false;
		return true;
	}

	static function isShareable(action:ExecutionAction):Bool {
		if (Sys.getEnv("HAXEON_DISABLE_ARTIFACT_CACHE") == "1" || action.outputs.length == 0)
			return false;
		return switch action.action {
			case Process(_, _, _, _): !StringTools.startsWith(action.id.key(),
					"cmake-configure:") && !StringTools.startsWith(action.id.key(), "native-cmake-configure:");
			case Compiler(_, _): false;
		};
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

	static function applyMode(path:String, mode:Int):Void {
		if (Sys.systemName() == "Windows")
			return;
		var digits = new StringBuf();
		for (shift in [6, 3, 0])
			digits.add((mode >> shift) & 7);
		if (Sys.command("chmod", [digits.toString(), path]) != 0)
			throw 'Could not restore permissions for $path';
	}

	static function removeTree(path:String):Void {
		if (!FileSystem.exists(path))
			return;
		if (!FileSystem.isDirectory(path)) {
			FileSystem.deleteFile(path);
			return;
		}
		for (entry in FileSystem.readDirectory(path))
			removeTree(Path.join([path, entry]));
		FileSystem.deleteDirectory(path);
	}
}
