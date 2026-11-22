package build.execution;

import build.execution.ContentDigestCache.DigestEntry;
import haxe.io.Path;
import sys.FileSystem;
import sys.io.File;
#if (target.threaded && !eval)
import sys.thread.Mutex;
#end

/**
 * Content digests kept on disk across processes, behind every `ContentDigestCache`, so a build does not read and hash the files
 * an earlier one already did: above all the compiler's own inputs (the pinned Haxe and the compiler's sources), which every
 * project's build fingerprints. One store per user, under the build cache (`~/.haxeon/cache/content-digests`), keyed by
 * absolute path, so every project and checkout shares it.
 *
 * An entry is the file's stat signature (device, inode, size, modification and status change times), the digest of its bytes and
 * when the hash began. It is kept, and served, only when both times are older than `ContentDigestCache.racyMarginSeconds` before
 * the hash began, the rule a persistent `ContentDigestCache` follows: timestamps are whole seconds, so only a file that had not
 * changed for a while when it was read cannot hide a later same-size edit behind an unchanged signature. A file just saved is
 * hashed again by each process until it settles. An edit that puts the modification time back still changes the status change
 * time, which no write can preserve.
 *
 * A process reads the file once, on its first lookup, and writes it back (`save`) only when it hashed something worth keeping,
 * under a name of its own and renamed into place, so concurrent processes never see a partial file; the last to save wins, which
 * at worst costs another process's new entries a hash next time. A save drops the entries the process neither used nor made once
 * they are older than `RETAIN_SECONDS`, so the files of deleted projects do not pile up.
 */
class DigestStore {
	static inline final HEADER = "haxeon-content-digests 1";

	static inline final RETAIN_SECONDS = 30 * 24 * 3600.0;

	static var sharedStore:Null<DigestStore> = null;
	#if (target.threaded && !eval)
	static final sharedMutex = new Mutex();
	#end

	final path:String;
	var entries:Null<Map<String, DigestEntry>> = null;
	final used:Map<String, Bool> = [];
	var dirty = false;
	#if (target.threaded && !eval)
	final mutex = new Mutex();
	#end

	/** Seconds since the epoch, for dropping old entries; replaceable so a test can age the store. */
	public var clock:Void->Float = Sys.time;

	public function new(path:String) {
		this.path = path;
	}

	/** This user's store, made on first use and shared by the whole process. */
	public static function shared():DigestStore {
		#if (target.threaded && !eval)
		sharedMutex.acquire();
		#end
		if (sharedStore == null)
			sharedStore = new DigestStore(Path.join([userCacheRoot(), "content-digests"]));
		var store = sharedStore;
		#if (target.threaded && !eval)
		sharedMutex.release();
		#end
		return store;
	}

	/** Writes the process's store back, when it has one with something new; a build calls it when it ends. */
	public static function saveShared():Void {
		var store = sharedStore;
		if (store != null)
			store.save();
	}

	static function userCacheRoot():String {
		var home = ProcessRunner.environmentValue(Sys.systemName() == "Windows" ? "USERPROFILE" : "HOME");
		if (home == null || home.length == 0)
			home = Sys.getCwd();
		return Path.join([home, ".haxeon", "cache"]);
	}

	/**
	 * The digest of the file at `key` (an absolute path) when its stat signature is `signature`, stored by a hash that began at
	 * least `marginSeconds` after both its times (`modified` and `changed`, in milliseconds), else null.
	 */
	public function find(key:String, signature:String, modified:Float, changed:Float,
			marginSeconds:Float):Null<DigestEntry> {
		lock();
		var entry = loaded().get(key);
		if (entry == null || entry.signature != signature
			|| !settled(modified, changed, entry.hashedAt, marginSeconds)) {
			unlock();
			return null;
		}
		used.set(key, true);
		unlock();
		return entry;
	}

	/** Keeps a digest this process made, when the file had settled before the hash began (`hashedAt`, in seconds). */
	public function record(key:String, signature:String, modified:Float, changed:Float, digest:String, hashedAt:Float,
			marginSeconds:Float):Void {
		hashedAt = Math.ffloor(hashedAt * 1000.0) / 1000.0;
		if (!settled(modified, changed, hashedAt, marginSeconds) || key.indexOf("\n") >= 0)
			return;
		lock();
		loaded().set(key, {signature: signature, digest: digest, hashedAt: hashedAt});
		used.set(key, true);
		dirty = true;
		unlock();
	}

	/** Writes the store back when this process added to it; a failure leaves the file as it was. */
	public function save():Void {
		lock();
		var current = entries;
		if (!dirty || current == null) {
			unlock();
			return;
		}
		dirty = false;
		var text = new StringBuf(), oldest = clock() - RETAIN_SECONDS;
		text.add(HEADER);
		text.add("\n");
		for (key => entry in current)
			if (used.exists(key) || entry.hashedAt >= oldest) {
				text.add(entry.digest);
				text.add("\t");
				text.add(Std.string(Math.fround(entry.hashedAt * 1000.0)));
				text.add("\t");
				text.add(entry.signature);
				text.add("\t");
				text.add(key);
				text.add("\n");
			}
		unlock();
		var temporary = path + ".tmp." + Std.random(1000000000);
		try {
			Directories.ensure(Path.directory(path));
			File.saveContent(temporary, text.toString());
			FileSystem.rename(temporary, path);
		} catch (_:Dynamic) {
			try
				FileSystem.deleteFile(temporary)
			catch (_:Dynamic) {}
		}
	}

	/** The entries, read from the file on first use; a missing or unreadable file is an empty store. */
	function loaded():Map<String, DigestEntry> {
		var current = entries;
		if (current != null)
			return current;
		var result = new Map<String, DigestEntry>();
		entries = result;
		var text = try File.getContent(path) catch (_:Dynamic) null;
		if (text == null || !StringTools.startsWith(text, HEADER + "\n"))
			return result;
		for (line in text.split("\n")) {
			var fields = line.split("\t");
			if (fields.length < 4)
				continue;
			var milliseconds = Std.parseFloat(fields[1]);
			if (Math.isNaN(milliseconds))
				continue;
			// The path is last, so one with a tab in it is joined back.
			result.set(fields.length == 4 ? fields[3] : fields.slice(3).join("\t"),
				{digest: fields[0], hashedAt: milliseconds / 1000.0, signature: fields[2]});
		}
		return result;
	}

	static inline function settled(modified:Float, changed:Float, hashedAt:Float, marginSeconds:Float):Bool {
		var limit = (hashedAt - marginSeconds) * 1000.0;
		return modified <= limit && changed <= limit;
	}

	inline function lock():Void {
		#if (target.threaded && !eval)
		mutex.acquire();
		#end
	}

	inline function unlock():Void {
		#if (target.threaded && !eval)
		mutex.release();
		#end
	}
}
