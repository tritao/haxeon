package build.execution;

import haxe.io.Path;
import sys.FileSystem;
import sys.io.File;
#if (target.threaded && !eval)
import sys.thread.Mutex;
#end

/** A file's digest, here and in a `DigestStore`. */
typedef DigestEntry = {
	/** size, mtime, ctime, device and inode as of the hash. */
	final signature:String;

	final digest:String;

	/** When the hash started, in seconds since the epoch, read before the bytes were. */
	final hashedAt:Float;
}

/**
 * Content hashes keyed by path. A file is re-hashed whenever its stat signature differs from the one it was hashed with.
 *
 * A cache made for one execution (the default) trusts that signature for its whole life. A persistent cache, kept across the
 * rebuilds of a watch session, must also survive an edit that leaves the signature unchanged: timestamps are whole seconds, so
 * a file rewritten with the same size within a second of being hashed looks untouched. Like git's index, a persistent cache
 * therefore only trusts an entry whose timestamps are older than `racyMarginSeconds` before the hash began; younger ("racily
 * clean") entries are re-hashed on the next lookup, which in practice is the file just saved, once.
 *
 * Behind every cache is a `DigestStore`, which keeps the digests of settled files (by the same rule) across processes: a file
 * this cache has not hashed yet is looked up there before it is read.
 */
class ContentDigestCache {
	final entries:Map<String, DigestEntry> = [];
	final persistent:Bool;
	final store:DigestStore;
	#if (target.threaded && !eval)
	final mutex = new Mutex();
	#end

	/** Covers one-second timestamp resolution plus clock skew between this machine and a network drive. */
	public var racyMarginSeconds = 3.0;

	/** Seconds since the epoch; replaceable so a test can age files without waiting. */
	public var clock:Void->Float = Sys.time;

	/** Files read and hashed so far. */
	public var hashes(default, null) = 0;

	/** `store` defaults to the user's (`DigestStore.shared`). */
	public function new(persistent:Bool = false, ?store:DigestStore) {
		this.persistent = persistent;
		this.store = store == null ? DigestStore.shared() : store;
	}

	/** Writes the store behind this cache back, when it gained digests worth keeping. */
	public function save():Void
		store.save();

	public function file(path:String):String {
		#if (target.threaded && !eval)
		mutex.acquire();
		#end
		try {
			// The path is the identity (Windows reports inode 0). A relative one is resolved against the current directory, which a
			// long-lived process may change; absolute paths, the common case, skip that syscall.
			var stat = FileSystem.stat(path),
				key = Path.isAbsolute(path) ? path : FileSystem.fullPath(path),
				signature = stat.dev + ":" + stat.ino + ":" + stat.size + ":" + stat.mtime.getTime() + ":"
					+ stat.ctime.getTime(),
				entry = entries.get(key);
			if (entry != null && entry.signature == signature && (!persistent || settled(stat, entry.hashedAt)))
				return release(entry.digest);
			var modified = stat.mtime.getTime(),
				changed = stat.ctime.getTime(),
				stored = store.find(key, signature, modified, changed, racyMarginSeconds);
			if (stored != null) {
				entries.set(key, stored);
				return release(stored.digest);
			}
			var hashedAt = clock(),
				digest = ContentDigest.makeHex(File.getBytes(path));
			hashes++;
			entries.set(key, {signature: signature, digest: digest, hashedAt: hashedAt});
			store.record(key, signature, modified, changed, digest, hashedAt, racyMarginSeconds);
			return release(digest);
		} catch (error:haxe.Exception) {
			#if (target.threaded && !eval)
			mutex.release();
			#end
			throw error;
		}
	}

	/** Neither timestamp is within the margin of the hash, so a later same-size edit could not have hidden behind it. */
	function settled(stat:sys.FileStat, hashedAt:Float):Bool {
		var limit = (hashedAt - racyMarginSeconds) * 1000.0;
		return stat.mtime.getTime() <= limit && stat.ctime.getTime() <= limit;
	}

	inline function release(digest:String):String {
		#if (target.threaded && !eval)
		mutex.release();
		#end
		return digest;
	}
}
