package tools;

import haxe.Json;
import haxeon.ProfileSpan;
import runtime.LoadedModule;
import runtime.PatchSet;
import runtime.Runtime;
import sys.FileSystem;
import sys.io.File;

private typedef LiveFunction = {final name:String; final id:Int;}
private typedef FullModule = {final module:haxe.io.Bytes; final identity:haxe.io.Bytes;}

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
		// The compiler publishes a patch before the full module, so the description can lead the module files.
		// Nothing is on screen yet, so waiting here is cheap; a compiler that writes no marker is trusted after a second.
		var waitingSince = Sys.time(), loadedBytes = readFullModule(path, description, false);
		while (loadedBytes == null) {
			Sys.sleep(0.02);
			description = readDescription(path);
			loadedBytes = readFullModule(path, description, Sys.time() - waitingSince > 1.0);
		}
		var module = Runtime.load(loadedBytes.module, loadedBytes.identity);
		var revision = description.revision;
		var rejectedPublication = "";
		// A reload whose full module is not published yet waits here while the current module keeps running.
		var pendingReload:Null<LiveDescription> = null, pendingSince = 0.0;
		try {
			Runtime.callStringArg(module, functionId(description, entry + ".start"), arguments);
			var running = true;
			while (running) {
				running = Runtime.callInt(module, functionId(description, entry + ".tick")) != 0;
				var published = readStamp(path);
				var seenAt = Sys.time();
				var candidate = published == null || published != stamp ? tryDescription(path) : null;
				var describedAt = Sys.time();
				if (candidate != null)
					stamp = published;
				if (candidate != null
					&& (candidate.revision != revision || candidate.moduleIdentity != description.moduleIdentity)
					&& publicationKey(candidate) != rejectedPublication) {
					if (candidate.moduleIdentity == description.moduleIdentity && candidate.patchAvailable && !candidate.requiresReload) {
						var patching = true;
						ProfileSpan.begin("live.patch");
						try {
							var patchBytes = File.getBytes(path + ".hlp"), readAt = Sys.time();
							Runtime.patchSet(module, new PatchSet(revision, candidate.revision, patchBytes, candidate.changedFunctions));
							patching = false;
							report('haxeon: patch timing ms: description=${Math.round((describedAt - seenAt) * 1000)} read=${Math.round((readAt - describedAt) * 1000)} apply=${Math.round((Sys.time() - readAt) * 1000)}');
							ProfileSpan.end("live.patch");
							// Function ids are stable across patches, so the summary stands in for the 1 MB full description.
							description = {
								revision: candidate.revision,
								moduleIdentity: candidate.moduleIdentity,
								requiresReload: candidate.requiresReload,
								patchAvailable: candidate.patchAvailable,
								changedFunctions: candidate.changedFunctions,
								identities: description.identities
							};
							revision = candidate.revision;
							rejectedPublication = "";
							report('haxeon: patched live module to revision $revision');
						} catch (error:Dynamic) {
							if (patching)
								ProfileSpan.end("live.patch");
							report('haxeon: patch rejected; reloading module: ${Std.string(error)}');
							var full = completeDescription(path, candidate);
							if (full == null)
								rejectedPublication = publicationKey(candidate);
							else {
								pendingReload = full;
								pendingSince = Sys.time();
							}
						}
					} else {
						report('haxeon: revision ${candidate.revision} cannot patch revision $revision (${reloadCause(description, candidate)}); reloading module');
						var full = completeDescription(path, candidate);
						if (full == null)
							rejectedPublication = publicationKey(candidate);
						else {
							pendingReload = full;
							pendingSince = Sys.time();
						}
					}
				}
				var pending = pendingReload;
				if (pending != null) {
					// Never block the app's thread on the compiler: check once per tick. A compiler that writes no marker
					// is trusted after a few seconds.
					var bytes = readFullModule(path, pending, Sys.time() - pendingSince > 3.0);
					if (bytes != null) {
						pendingReload = null;
						var replacement = reload(module, description, pending, bytes, entry, arguments);
						if (replacement == null)
							rejectedPublication = publicationKey(pending);
						else {
							module = replacement;
							description = pending;
							revision = pending.revision;
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

	static function reload(current:LoadedModule, previous:LiveDescription, next:LiveDescription, bytes:FullModule, entry:String,
			arguments:String):Null<LoadedModule> {
		ProfileSpan.begin("live.reload");
		var replacement = try reloadModule(current, previous, next, bytes, entry, arguments) catch (error:Dynamic) {
			ProfileSpan.end("live.reload");
			throw error;
		}
		ProfileSpan.end("live.reload");
		return replacement;
	}

	static function reloadModule(current:LoadedModule, previous:LiveDescription, next:LiveDescription, bytes:FullModule, entry:String,
			arguments:String):Null<LoadedModule> {
		var state:String;
		try
			state = Runtime.callString(current, functionId(previous, entry + ".saveState"))
		catch (error:Dynamic) {
			report('haxeon: could not save live state; keeping revision ${previous.revision}: ${Std.string(error)}');
			return null;
		}
		var replacement:LoadedModule;
		try {
			replacement = Runtime.load(bytes.module, bytes.identity);
		} catch (error:Dynamic) {
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

	/**
	 * The full module and its identity when the compiler's `.live.full` marker says they belong to `target`, checking the
	 * marker again after reading; null when they don't yet (a newer build may be landing). With `trustMissing`, files with
	 * no marker at all are taken as they are, which is what a compiler that writes no marker leaves. Never waits.
	 */
	static function readFullModule(path:String, target:LiveDescription, trustMissing:Bool):Null<FullModule> {
		var wanted = publicationKey(target), marker = readMarker(path);
		if (marker == wanted) {
			var bytes:FullModule = {module: File.getBytes(path), identity: File.getBytes(path + ".hli")};
			if (readMarker(path) == wanted)
				return bytes;
			return null;
		}
		if (marker == null && trustMissing)
			return {module: File.getBytes(path), identity: File.getBytes(path + ".hli")};
		return null;
	}

	static function readMarker(path:String):Null<String> {
		try
			return File.getContent(path + ".live.full")
		catch (_:Dynamic)
			return null;
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
	static function readDescription(path:String, file:String = ".live.json"):LiveDescription {
		var value:Dynamic = Json.parse(File.getContent(path + file));
		var changed:Array<Dynamic> = value.changedFunctions,
			identities:Array<Dynamic> = value.identities;
		return {
			revision: value.revision,
			moduleIdentity: value.moduleIdentity,
			requiresReload: value.requiresReload,
			patchAvailable: value.patchAvailable,
			changedFunctions: [for (id in changed) (id : Int)],
			identities: [
				for (item in identities)
					({
						name:item.name, id:item.id
					} : LiveFunction)
			]
		};
	}

	/** The small summary the compiler writes beside the full description, so a patch does not parse the whole function list. */
	static function tryDescription(path:String):Null<LiveDescription> {
		try
			return readDescription(path, FileSystem.exists(path + ".live.patch.json") ? ".live.patch.json" : ".live.json")
		catch (_:Dynamic)
			return null;
	}

	/** The full description of the summary's publication, or null when another build has replaced it since. */
	static function completeDescription(path:String, summary:LiveDescription):Null<LiveDescription> {
		var full = try readDescription(path) catch (_:Dynamic) null;
		return full != null && publicationKey(full) == publicationKey(summary) ? full : null;
	}

	static function functionId(description:LiveDescription, name:String):Int {
		for (item in description.identities)
			if (item.name == name)
				return item.id;
		throw 'Missing live entry point "$name"';
	}
}
