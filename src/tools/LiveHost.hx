package tools;

import haxe.Json;
import runtime.LoadedModule;
import runtime.PatchSet;
import runtime.Runtime;
import sys.io.File;

private typedef LiveFunction = {final name:String; final id:Int;}
private typedef LiveDescription = {
	final revision:Int;
	final moduleIdentity:String;
	final requiresReload:Bool;
	final patchAvailable:Bool;
	final changedFunctions:Array<Int>;
	final identities:Array<LiveFunction>;
}

/** Stable process that calls one application pump step at a time. */
class LiveHost {
	static function main():Void {
		var args = Sys.args();
		if (args.length != 3)
			throw "Usage: LiveHost <module.hl> <entry> <arguments-json>";
		var path = args[0], entry = args[1], arguments = args[2];
		var description = readDescription(path);
		var module = Runtime.load(File.getBytes(path), File.getBytes(path + ".hli"));
		var revision = description.revision;
		try {
			Runtime.callStringArg(module, functionId(description, entry + ".start"), arguments);
			var running = true;
			while (running) {
				running = Runtime.callInt(module, functionId(description, entry + ".tick")) != 0;
				var candidate = tryDescription(path);
				if (candidate != null && (candidate.revision != revision || candidate.moduleIdentity != description.moduleIdentity)) {
					if (candidate.moduleIdentity == description.moduleIdentity && candidate.patchAvailable && !candidate.requiresReload) {
						try {
							Runtime.patchSet(module, new PatchSet(revision, candidate.revision,
								File.getBytes(path + ".hlp"), candidate.changedFunctions));
							description = candidate;
							revision = candidate.revision;
							Sys.println('haxeon: patched live module to revision $revision');
						} catch (error:Dynamic) {
							Sys.println('haxeon: patch rejected; reloading module: ${Std.string(error)}');
							module = reload(module, description, candidate, path, entry, arguments);
							description = candidate;
							revision = candidate.revision;
						}
					} else {
						module = reload(module, description, candidate, path, entry, arguments);
						description = candidate;
						revision = candidate.revision;
					}
				}
			}
			var status = Runtime.callInt(module, functionId(description, entry + ".close"));
			if (status != 0) Sys.exit(status);
		} catch (error:Dynamic) {
			try Runtime.callInt(module, functionId(description, entry + ".close")) catch (_:Dynamic) {}
			Runtime.dispose(module);
			throw error;
		}
		Runtime.dispose(module);
	}

	static function reload(current:LoadedModule, previous:LiveDescription, next:LiveDescription,
			path:String, entry:String, arguments:String):LoadedModule {
		var replacement = Runtime.load(File.getBytes(path), File.getBytes(path + ".hli"));
		try {
			var state = Runtime.callString(current, functionId(previous, entry + ".saveState"));
			Runtime.callInt(current, functionId(previous, entry + ".close"));
			Runtime.callStringArg(replacement, functionId(next, entry + ".start"), arguments);
			Runtime.callStringArg(replacement, functionId(next, entry + ".restoreState"), state);
			Runtime.dispose(current);
			Sys.println('haxeon: reloaded live module to revision ${next.revision}');
			return replacement;
		} catch (error:Dynamic) {
			Runtime.dispose(replacement);
			throw error;
		}
	}

	static function readDescription(path:String):LiveDescription
		return Json.parse(File.getContent(path + ".live.json"));

	static function tryDescription(path:String):Null<LiveDescription> {
		try return readDescription(path) catch (_:Dynamic) return null;
	}

	static function functionId(description:LiveDescription, name:String):Int {
		for (item in description.identities)
			if (item.name == name) return item.id;
		throw 'Missing live entry point "$name"';
	}
}
