package haxeon.audio;

import haxeon.platform.NativeKitError;
import std.fs.FileError;

/** Why `SoundFontCache.acquire` could not lease a bank. */
enum SoundFontLoadError {
	/** The file could not be read. */
	File(error:FileError);

	/** The file is not an SF2 bank the decoder reads, or decoding it failed. */
	Decode(error:NativeKitError);

	/** The file is larger than the cache's whole source-byte budget, so it never fits. */
	TooLarge;

	/** It does not fit now: every bank the budget holds is leased, so none can be evicted. Retry once leases end. */
	Pinned;

	/** What went wrong, in a few words. */
	public function describe():String
		return switch this {
			case File(error): "SoundFont file: " + error.describe();
			case Decode(error): "SoundFont decode: " + error.describe();
			case TooLarge: "the SoundFont is larger than the cache budget";
			case Pinned: "the SoundFont cache budget is held by active leases";
		}
}
