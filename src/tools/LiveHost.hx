package tools;

import haxe.Json;
import haxeon.ProfileSpan;
import runtime.LoadedModule;
import runtime.LiveRefusal;
import runtime.PatchSet;
import runtime.Runtime;
import runtime.RuntimeError;
import runtime.RuntimeStatus;
import sys.FileSystem;
import sys.io.File;

private typedef LiveFunction = {final name:String; final id:Int;}
private typedef FullModule = {final module:haxe.io.Bytes; final identity:haxe.io.Bytes;}

private typedef LiveDescription = {
	final revision:Int;
	/** The revision the build's patch applies to; -1 from a compiler that does not say. */
	final baseRevision:Int;
	final moduleIdentity:String;
	final requiresReload:Bool;
	/** Why the compiler could not publish a patch, as "code entity" lines. */
	final reloadReasons:Array<String>;
	final patchAvailable:Bool;
	final changedFunctions:Array<Int>;
	final identities:Array<LiveFunction>;
}

/** Stable process that calls one application pump step at a time. */
class LiveHost {
	/**
	 * `haxeon run --watch --live --strict-live`: an edit that cannot patch is reported and left out instead of reloading the
	 * module, so a reload the edit should not have needed cannot pass unnoticed. That includes the builds of a compiler that
	 * lost the running module's history (a new compiler session, after a worker crash say, or one that numbers the module
	 * from scratch): none of them can patch, so each is refused, and starting the app afresh loads the latest.
	 */
	static final strict:Bool = Sys.getEnv("HAXEON_LIVE_STRICT") == "1";

	static function main():Void {
		var args = Sys.args();
		if (args.length != 3)
			throw "Usage: LiveHost <module.hl> <entry> <arguments-json>";
		var path = args[0], entry = args[1], arguments = args[2];
		var stamp = readStamp(path);
		var description = readDescription(path);
		// The compiler publishes a patch before the full module, so the description can lead the module files.
		// Nothing is on screen yet, so waiting here is cheap; a compiler that writes no marker is trusted after a second.
		var waitingSince = Sys.time(),
			loadedBytes = readFullModule(path, description, false);
		while (loadedBytes == null) {
			Sys.sleep(0.02);
			description = readDescription(path);
			loadedBytes = readFullModule(path, description, Sys.time() - waitingSince > 1.0);
		}
		var module = Runtime.load(loadedBytes.module, loadedBytes.identity);
		var revision = description.revision;
		var rejectedPublication = "";
		// Strict mode: why the compiler no longer has the running module's history, once a build showed it. No build of that
		// compiler can patch this app again, so each is refused; starting the app afresh loads the latest.
		var lostHistory:Null<String> = null;
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
					// The same module numbered from scratch is a history the running module never had, like a new session.
					var restarted = candidate.moduleIdentity == description.moduleIdentity && candidate.revision < revision,
						sameHistory = candidate.moduleIdentity == description.moduleIdentity && !restarted,
						patchable = sameHistory && candidate.patchAvailable && !candidate.requiresReload;
					if (strict && !sameHistory && lostHistory == null)
						lostHistory = reloadCause(description, candidate);
					if (strict && lostHistory != null)
						rejectedPublication = refuse(path, description, revision, candidate,
							'the compiler no longer has the history of the running module ($lostHistory), so none of its builds can patch it; restart the app to load revision ${candidate.revision}',
							false);
					else if (strict && patchable && candidate.baseRevision >= 0 && candidate.baseRevision != revision)
						rejectedPublication = refuse(path, description, revision, candidate,
							'its patch applies to revision ${candidate.baseRevision}, which this app refused; the next build patches revision $revision', true);
					else if (patchable) {
						var failure:Null<String> = null, applied = false, held = false, readAt = describedAt;
						ProfileSpan.begin("live.patch");
						try {
							var patchBytes = File.getBytes(path + ".hlp");
							readAt = Sys.time();
							// An app that rebuilds its UI from its code lets go of it around the patch (`Runtime.patchSetRebuilding`).
							Runtime.patchSetRebuilding(module, new PatchSet(revision, candidate.revision, patchBytes, candidate.changedFunctions),
								optionalFunctionId(description, entry + "." + LIVE_RELEASE), optionalFunctionId(description, entry + "." + LIVE_REBUILD));
							applied = true;
						} catch (error:RuntimeError) {
							failure = error.message;
							applied = error.status == RuntimeStatus.MigrationFailed;
							// Closures the app stored still reach a function the edit drops; the message names it and what holds them.
							held = error.status == RuntimeStatus.ClosuresHeld;
						} catch (error:Dynamic) {
							failure = Std.string(error);
						}
						ProfileSpan.end("live.patch");
						if (applied) {
							// The summary stands in for the 1 MB full description.
							description = patchedDescription(description, candidate);
							revision = candidate.revision;
							rejectedPublication = "";
						}
						if (failure == null) {
							report('haxeon: patch timing ms: description=${Math.round((describedAt - seenAt) * 1000)} read=${Math.round((readAt - describedAt) * 1000)} apply=${Math.round((Sys.time() - readAt) * 1000)}');
							report('haxeon: patched live module to revision $revision');
						} else if (applied && strict)
							// The revision runs and cannot be taken back; the objects that missed their initializers stay as they are.
							banner('LIVE PATCH INCOMPLETE (--strict-live): revision $revision runs, but objects made before it lack field values', [
								failure,
								'those fields hold zero values (null, 0, false); restart the app to run revision $revision from a fresh state'
							]);
						else if (strict)
							rejectedPublication = refuse(path, description, revision, candidate, held ? failure : 'the runtime rejected its patch: $failure', true);
						else {
							report(applied ? 'haxeon: patch incomplete; reloading module: $failure' : 'haxeon: patch rejected; reloading module: $failure');
							var full = completeDescription(path, candidate);
							if (full == null)
								rejectedPublication = publicationKey(candidate);
							else {
								pendingReload = full;
								pendingSince = Sys.time();
							}
						}
					} else if (strict)
						rejectedPublication = refuse(path, description, revision, candidate, reloadCause(description, candidate), true);
					else {
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
		if (candidate.revision < current.revision)
			return 'the compiler numbered the module from scratch';
		if (candidate.requiresReload)
			return 'the build requires a reload'
				+ (candidate.reloadReasons.length == 0 ? '' : ': ' + candidate.reloadReasons.join(", "));
		return 'the build carries no patch';
	}

	/**
	 * Strict mode: the running revision stays, and the edit is reported where it cannot be missed. With `recordForCompiler`
	 * the compiler is told in `<module>.live.refused` (`LiveRefusal`), so its next build patches the revision this app runs
	 * instead of the refused one. Returns the refused publication's key, which the host passes over from then on.
	 */
	static function refuse(path:String, current:LiveDescription, revision:Int, candidate:LiveDescription, cause:String,
			recordForCompiler:Bool):String {
		if (recordForCompiler)
			try
				File.saveContent(LiveRefusal.path(path), new LiveRefusal(current.moduleIdentity, revision, candidate.revision).encode())
			catch (error:Dynamic)
				report('haxeon: could not tell the compiler about the refusal: ${Std.string(error)}');
		banner('LIVE PATCH REFUSED (--strict-live): revision ${candidate.revision} was not applied; still running revision $revision',
			recordForCompiler ? [cause, 'the next build patches revision $revision with the refused edits in it'] : [cause]);
		return publicationKey(candidate);
	}

	/** The strict-mode banner: a headline and the lines that explain it, framed so a log reader cannot miss them. */
	static function banner(headline:String, lines:Array<String>):Void {
		report('haxeon: ================================================================');
		report('haxeon: $headline');
		for (line in lines)
			report('haxeon: $line');
		report('haxeon: ================================================================');
	}

	/** The running module's description once `candidate`'s patch applied: function ids are stable, so they carry over. */
	static function patchedDescription(current:LiveDescription, candidate:LiveDescription):LiveDescription
		return {
			revision: candidate.revision,
			baseRevision: candidate.baseRevision,
			moduleIdentity: candidate.moduleIdentity,
			requiresReload: candidate.requiresReload,
			reloadReasons: candidate.reloadReasons,
			patchAvailable: candidate.patchAvailable,
			changedFunctions: candidate.changedFunctions,
			identities: current.identities
		};

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
			identities:Array<Dynamic> = value.identities,
			reasons:Null<Array<Dynamic>> = value.reloadReasons;
		var base:Null<Dynamic> = value.baseRevision;
		return {
			revision: value.revision,
			baseRevision: base == null ? -1 : (base : Int),
			moduleIdentity: value.moduleIdentity,
			requiresReload: value.requiresReload,
			reloadReasons: reasons == null ? [] : [for (reason in reasons) Std.string(reason.code) + " " + Std.string(reason.entityId)],
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

	/**
	 * Optional functions of the app's entry class a host calls around each patch (`Runtime.patchSetRebuilding`):
	 * `liveRelease()` lets go of what the app rebuilds from its code, its UI and the callbacks it holds, and `liveRebuild()`
	 * builds it again, from the patched code when the patch applied.
	 */
	public static inline final LIVE_RELEASE:String = "liveRelease";

	public static inline final LIVE_REBUILD:String = "liveRebuild";

	static function optionalFunctionId(description:LiveDescription, name:String):Null<Int> {
		for (item in description.identities)
			if (item.name == name)
				return item.id;
		return null;
	}

	static function functionId(description:LiveDescription, name:String):Int {
		for (item in description.identities)
			if (item.name == name)
				return item.id;
		throw 'Missing live entry point "$name"';
	}
}
