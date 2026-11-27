package haxeon.audio;

import haxe.io.Bytes;
import haxeon.platform.BindingError;
import haxeon.platform.NativeKitError;

import haxeon.audio.SoundFont.SoundFontPresetInfo;
import std.fs.Files;
import std.fs.Path;
import sys.thread.Condition;

private typedef CachedBank = {
	var path:String;
	var sourceBytes:Int;
	/** Whether it counts against the limits: from when its file is read until it leaves the cache. */
	var admitted:Bool;
	var font:Null<SoundFont>;
	var inventory:Array<SoundFontPresetInfo>;
	var users:Int;
	var loading:Bool;
	/** Why the load failed, which the requests that waited on it answer too. */
	var failure:Null<SoundFontLoadError>;
	/** What the load threw instead, which they throw too. */
	var thrown:Dynamic;
	var stamp:Float;
}

/** Counts for a SoundFont cache: what it holds and how its loads went. */
typedef SoundFontCacheStats = {
	var banks:Int;
	var loading:Int;
	var leases:Int;
	var sourceBytes:Int;
	var loads:Int;
	var hits:Int;
	var evictions:Int;
	var failedLoads:Int;
}

/** Scoped immutable SF2 assets, shared by independent instruments. Never use on the audio thread.
 * Bounds resident banks and source bytes, counted from when a bank's file has been read;
 * decoded/playback memory is not measured by sourceBytes. Files are immutable within a cache scope. Idle banks are LRU
 * evicted, leased banks stay pinned. Concurrent requests for one canonical path share one load.
 * Close before NativeKit shutdown; outstanding leases remain usable until individually released.
 */
class SoundFontCache implements Disposable {
	final condition = new Condition();
	final entries:Map<String, CachedBank> = new Map();
	final maxBanks:Int;
	final maxSourceBytes:Int;
	var bankCount = 0;
	var sourceBytes = 0;
	var stamp:Float = 0;
	var loads = 0;
	var hits = 0;
	var evictions = 0;
	var failedLoads = 0;
	var closed = false;

	/** A cache keeping at most `maxBanks` banks and `maxSourceBytes` bytes of their files. */
	public function new(maxBanks:Int = 4, maxSourceBytes:Int = 8 * 1024 * 1024) {
		if (maxBanks < 1 || maxBanks > 64 || maxSourceBytes < 1 || maxSourceBytes > 512 * 1024 * 1024)
			throw BindingError.invalidArgument("SoundFontCache.new", "Invalid SoundFont cache limits");
		this.maxBanks = maxBanks;
		this.maxSourceBytes = maxSourceBytes;
	}

	/**
	 * A lease on the bank in the file `path`, loading it unless the cache holds it; acquire on a preparation thread. A
	 * lease owns access to definitions, not playback state. A disposed cache throws a `BindingError`.
	 */
	public function acquire(path:Path):Result<SoundFontLease, SoundFontLoadError> {
		var key = switch Files.canonical(path) {
			case Ok(found): found.toString();
			case Err(error): return Err(File(error));
		};
		condition.acquire();
		if (closed) {
			condition.release();
			throw BindingError.disposed("SoundFontCache.acquire", "SoundFont cache disposed");
		}
		var existing = entries.get(key);
		if (existing != null) {
			// Pin before waiting: the first caller may release/evict immediately after loading.
			existing.users++;
			while (existing.loading && !closed) condition.wait();
			var failed = existing.failure != null || existing.thrown != null;
			if (closed || failed) {
				existing.users--;
				var close = closed && !existing.loading && !failed && existing.users == 0;
				if (close) remove(existing);
				condition.release();
				if (close) existing.font.dispose();
				if (existing.failure != null)
					return Err(existing.failure);
				if (existing.thrown != null)
					throw existing.thrown;
				throw BindingError.disposed("SoundFontCache.acquire", "SoundFont cache disposed");
			}
			existing.stamp = ++stamp;
			hits++;
			condition.release();
			return Ok(new SoundFontLease(this, existing));
		}
		// Registered before the file is read, so concurrent requests for it wait on this load.
		var entry:CachedBank = {
			path: key,
			sourceBytes: 0,
			admitted: false,
			font: null,
			inventory: [],
			users: 1,
			loading: true,
			failure: null,
			thrown: null,
			stamp: ++stamp
		};
		entries.set(key, entry);
		condition.release();

		var loaded:Result<SoundFont, SoundFontLoadError>;
		try {
			loaded = load(entry);
		} catch (unexpected:Dynamic) {
			fail(entry, null, unexpected);
			throw unexpected;
		}
		var font = switch loaded {
			case Ok(font): font;
			case Err(error):
				fail(entry, error, null);
				return Err(error);
		};
		try {
			var inventory = font.presets();
			condition.acquire();
			if (closed) {
				condition.release();
				throw BindingError.disposed("SoundFontCache.acquire", "SoundFont cache disposed during loading");
			}
			entry.font = font;
			entry.inventory = inventory;
			entry.loading = false;
			loads++;
			condition.broadcast();
			condition.release();
		} catch (unexpected:Dynamic) {
			fail(entry, null, unexpected);
			font.dispose();
			throw unexpected;
		}
		return Ok(new SoundFontLease(this, entry));
	}

	/** Reads `entry`'s file, admits it within the limits, and decodes it. */
	function load(entry:CachedBank):Result<SoundFont, SoundFontLoadError> {
		var data:Bytes = switch Files.read(entry.path) {
			case Ok(read): read;
			case Err(error): return Err(File(error));
		};
		if (data.length == 0)
			return Err(Decode(InvalidData("the file is empty")));
		var victims = switch admit(entry, data.length) {
			case Ok(evicted): evicted;
			case Err(error): return Err(error);
		};
		closeFonts(victims);
		return switch SoundFont.fromMemory(data) {
			case Ok(font): Ok(font);
			case Err(error): Err(Decode(error));
		};
	}

	/**
	 * Counts `entry`, of `bytes` bytes, against the limits, evicting the least recently used idle banks it needs room
	 * from; answers them, to close outside the mutex. Evicts nothing unless the whole request fits.
	 */
	function admit(entry:CachedBank, bytes:Int):Result<Array<SoundFont>, SoundFontLoadError> {
		if (bytes > maxSourceBytes)
			return Err(TooLarge);
		condition.acquire();
		var selected:Array<CachedBank> = [];
		var remainingBanks = bankCount;
		var remainingBytes = sourceBytes;
		while (remainingBanks >= maxBanks || remainingBytes + bytes > maxSourceBytes) {
			var oldest:Null<CachedBank> = null;
			for (other in entries) if (other.admitted && !other.loading && other.users == 0
				&& selected.indexOf(other) < 0 && (oldest == null || other.stamp < oldest.stamp)) oldest = other;
			if (oldest == null) {
				condition.release();
				return Err(Pinned);
			}
			selected.push(oldest);
			remainingBanks--;
			remainingBytes -= oldest.sourceBytes;
		}
		var victims:Array<SoundFont> = [];
		for (victim in selected) {
			remove(victim);
			victims.push(cast victim.font);
			evictions++;
		}
		entry.admitted = true;
		entry.sourceBytes = bytes;
		bankCount++;
		sourceBytes += bytes;
		condition.release();
		return Ok(victims);
	}

	/** Ends `entry`'s load as failed, for `failure` or with `thrown`, and gives back its reservation. */
	function fail(entry:CachedBank, failure:Null<SoundFontLoadError>, thrown:Dynamic):Void {
		condition.acquire();
		entry.failure = failure;
		entry.thrown = thrown;
		entry.loading = false;
		entry.users--;
		remove(entry);
		failedLoads++;
		condition.broadcast();
		condition.release();
	}

	// Called with the mutex held. Native destruction always occurs after releasing it.
	function remove(entry:CachedBank):Void {
		entries.remove(entry.path);
		if (!entry.admitted)
			return;
		entry.admitted = false;
		bankCount--;
		sourceBytes -= entry.sourceBytes;
	}
	@:allow(haxeon.audio.SoundFontLease)
	private function release(entry:CachedBank):Void {
		condition.acquire();
		entry.users--;
		entry.stamp = ++stamp;
		var close = closed && entry.users == 0;
		if (close) remove(entry);
		condition.release();
		if (close) entry.font.dispose();
	}

	/** Its counts. */
	public function stats():SoundFontCacheStats {
		condition.acquire();
		var loading = 0;
		var leases = 0;
		for (entry in entries) {
			if (entry.loading) loading++;
			leases += entry.users;
		}
		var result = {
			banks: bankCount,
			loading: loading,
			leases: leases,
			sourceBytes: sourceBytes,
			loads: loads,
			hits: hits,
			evictions: evictions,
			failedLoads: failedLoads
		};
		condition.release();
		return result;
	}
	/** Reject new acquisitions; outstanding leases retain their bank until released. */
	public function dispose():Void {
		var victims:Array<SoundFont> = [];
		condition.acquire();
		if (closed) {
			condition.release();
			return;
		}
		closed = true;
		var idle = [for (entry in entries) if (!entry.loading && entry.users == 0) entry];
		for (entry in idle) {
			remove(entry);
			victims.push(cast entry.font);
		}
		condition.broadcast();
		condition.release();
		closeFonts(victims);
	}
	static function closeFonts(fonts:Array<SoundFont>):Void {
		var failure:Dynamic = null;
		for (font in fonts) try font.dispose() catch (error:Dynamic) {
			if (failure == null) failure = error;
		}
		if (failure != null) throw failure;
	}
}

/** Caller-owned pin. Dispose after consumers have finished creating instruments.
 * Native instruments retain samples independently after release. A lease has one owning thread.
 */
class SoundFontLease implements Disposable {
	final cache:SoundFontCache;
	final entry:CachedBank;
	var disposed = false;
	@:allow(haxeon.audio.SoundFontCache)
	private function new(cache:SoundFontCache, entry:CachedBank) {
		this.cache = cache;
		this.entry = entry;
	}
	function ensureLive():Void {
		if (disposed) throw BindingError.disposed("SoundFontLease.ensureLive", "SoundFont lease disposed");
	}

	/** The bank's presets. */
	public function presets():Array<SoundFontPresetInfo> {
		ensureLive();
		return [for (info in entry.inventory) {
			index: info.index, bank: info.bank, program: info.program, name: info.name
		}];
	}

	/** Preset `index`, played at `gain`, valid while the lease is. */
	public function preset(index:Int, gain:Float = 1):InstrumentDefinition {
		ensureLive();
		if (index < 0 || index >= entry.inventory.length || !Math.isFinite(gain) || gain < 0 || gain > 4)
			throw BindingError.invalidArgument("SoundFontLease.preset", "Invalid cached SoundFont preset");
		return new LeasedPreset(this, index, gain);
	}
	internal function createInstrument(engine:DspEngine, index:Int, gain:Float = 1):DspInstrument {
		ensureLive();
		var font:SoundFont = cast entry.font;
		return font.preset(index, gain).createInstrument(engine);
	}
	public function dispose():Void {
		if (disposed) return;
		disposed = true;
		cache.release(entry);
	}
}

private class LeasedPreset implements InstrumentDefinition {
	final lease:SoundFontLease;
	final index:Int;
	final gain:Float;
	public function new(lease:SoundFontLease, index:Int, gain:Float) {
		this.lease = lease;
		this.index = index;
		this.gain = gain;
	}
	public function createInstrument(engine:DspEngine):DspInstrument return lease.createInstrument(engine, index, gain);
}
