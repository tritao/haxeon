package tools;

import haxe.Json;
import haxeon.ProfileSpan;
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
		var stamp = readStamp(path);
		var description = readDescription(path);
		var module = Runtime.load(File.getBytes(path), File.getBytes(path + ".hli"));
		var revision = description.revision;
		var rejectedPublication = "";
		try {
			Runtime.callStringArg(module, functionId(description, entry + ".start"), arguments);
			var running = true;
			while (running) {
				running = Runtime.callInt(module, functionId(description, entry + ".tick")) != 0;
				var published = readStamp(path);
				var candidate = published == null || published != stamp ? tryDescription(path) : null;
				if (candidate != null)
					stamp = published;
				if (candidate != null
					&& (candidate.revision != revision || candidate.moduleIdentity != description.moduleIdentity)
					&& publicationKey(candidate) != rejectedPublication) {
					if (candidate.moduleIdentity == description.moduleIdentity && candidate.patchAvailable && !candidate.requiresReload) {
						var patching = true;
						ProfileSpan.begin("live.patch");
						try {
							Runtime.patchSet(module, new PatchSet(revision, candidate.revision, File.getBytes(path + ".hlp"), candidate.changedFunctions));
							patching = false;
							ProfileSpan.end("live.patch");
							description = candidate;
							revision = candidate.revision;
							rejectedPublication = "";
							report('haxeon: patched live module to revision $revision');
						} catch (error:Dynamic) {
							if (patching)
								ProfileSpan.end("live.patch");
							report('haxeon: patch rejected; reloading module: ${Std.string(error)}');
							var replacement = reload(module, description, candidate, path, entry, arguments);
							if (replacement == null)
								rejectedPublication = publicationKey(candidate);
							else {
								module = replacement;
								description = candidate;
								revision = candidate.revision;
								rejectedPublication = "";
							}
						}
					} else {
						report('haxeon: revision ${candidate.revision} cannot patch revision $revision (${reloadCause(description, candidate)}); reloading module');
						var replacement = reload(module, description, candidate, path, entry, arguments);
						if (replacement == null)
							rejectedPublication = publicationKey(candidate);
						else {
							module = replacement;
							description = candidate;
							revision = candidate.revision;
							rejectedPublication = "";
						}
					}
				}
			}
			var status = Runtime.callInt(module, functionId(description, entry + ".close"));
			if (status != 0)
				Sys.exit(status);
		} catch (error:Dynamic) {
			try
				Runtime.callInt(module, functionId(description, entry + ".close"))
			catch (_:Dynamic) {}
			Runtime.dispose(module);
			throw error;
		}
		Runtime.dispose(module);
	}

	static function reload(current:LoadedModule, previous:LiveDescription, next:LiveDescription, path:String, entry:String,
			arguments:String):Null<LoadedModule> {
		ProfileSpan.begin("live.reload");
		var replacement = try reloadModule(current, previous, next, path, entry, arguments) catch (error:Dynamic) {
			ProfileSpan.end("live.reload");
			throw error;
		};
		ProfileSpan.end("live.reload");
		return replacement;
	}

	static function reloadModule(current:LoadedModule, previous:LiveDescription, next:LiveDescription, path:String, entry:String,
			arguments:String):Null<LoadedModule> {
		var state:String;
		try
			state = Runtime.callString(current, functionId(previous, entry + ".saveState"))
		catch (error:Dynamic) {
			report('haxeon: could not save live state; keeping revision ${previous.revision}: ${Std.string(error)}');
			return null;
		}
		var replacement:LoadedModule;
		try
			replacement = Runtime.load(File.getBytes(path), File.getBytes(path + ".hli"))
		catch (error:Dynamic) {
			report('haxeon: could not load replacement; keeping revision ${previous.revision}: ${Std.string(error)}');
			return null;
		}
		var oldClosed = false;
		try {
			oldClosed = true;
			Runtime.callInt(current, functionId(previous, entry + ".close"));
			Runtime.callStringArg(replacement, functionId(next, entry + ".start"), arguments);
			Runtime.callStringArg(replacement, functionId(next, entry + ".restoreState"), state);
			try
				Runtime.dispose(current)
			catch (error:Dynamic)
				report('haxeon: previous module retirement is pending: ${Std.string(error)}');
			report('haxeon: reloaded live module to revision ${next.revision}');
			return replacement;
		} catch (error:Dynamic) {
			try
				Runtime.callInt(replacement, functionId(next, entry + ".close"))
			catch (_:Dynamic) {}
			try
				Runtime.dispose(replacement)
			catch (_:Dynamic) {}
			if (oldClosed) {
				Runtime.callStringArg(current, functionId(previous, entry + ".start"), arguments);
				Runtime.callStringArg(current, functionId(previous, entry + ".restoreState"), state);
			}
			report('haxeon: reload failed; restored revision ${previous.revision}: ${Std.string(error)}');
			return null;
		}
	}

	static function reloadCause(current:LiveDescription, candidate:LiveDescription):String {
		if (candidate.moduleIdentity != current.moduleIdentity)
			return 'module identity changed from ${current.moduleIdentity} to ${candidate.moduleIdentity}';
		if (candidate.requiresReload)
			return 'the build requires a reload';
		return 'the build carries no patch';
	}

	/** Flushes each message because the watcher redirects this process's output to a log file. */
	static function report(message:String):Void {
		Sys.println(message);
		Sys.stdout().flush();
	}

	static function publicationKey(description:LiveDescription):String
		return description.moduleIdentity + ":" + description.revision;

	/** The publication key the compiler stamps beside the description; null when a compiler that writes no stamp built it. */
	static function readStamp(path:String):Null<String> {
		try
			return File.getContent(path + ".live.stamp")
		catch (_:Dynamic)
			return null;
	}

	/** Built field by field: Haxeon cannot yet cast a parsed Dynamic object to a structure type. */
	static function readDescription(path:String):LiveDescription {
		var value:Dynamic = Json.parse(File.getContent(path + ".live.json"));
		var changed:Array<Dynamic> = value.changedFunctions, identities:Array<Dynamic> = value.identities;
		return {
			revision: value.revision,
			moduleIdentity: value.moduleIdentity,
			requiresReload: value.requiresReload,
			patchAvailable: value.patchAvailable,
			changedFunctions: [for (id in changed) (id : Int)],
			identities: [for (item in identities) ({name: item.name, id: item.id} : LiveFunction)]
		};
	}

	static function tryDescription(path:String):Null<LiveDescription> {
		try
			return readDescription(path)
		catch (_:Dynamic)
			return null;
	}

	static function functionId(description:LiveDescription, name:String):Int {
		for (item in description.identities)
			if (item.name == name)
				return item.id;
		throw 'Missing live entry point "$name"';
	}
}
