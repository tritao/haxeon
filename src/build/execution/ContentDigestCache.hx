package build.execution;

import haxe.crypto.Sha256;
import sys.FileSystem;
import sys.io.File;
#if (target.threaded && !eval)
import sys.thread.Mutex;
#end

/** Content hashes shared by actions during one execution, never trusted across builds. */
class ContentDigestCache {
	final values:Map<String, String> = [];
	#if (target.threaded && !eval)
	final mutex = new Mutex();
	#end

	public function new() {}

	public function file(path:String):String {
		#if (target.threaded && !eval)
		mutex.acquire();
		#end
		try {
			var stat = FileSystem.stat(path),
				key = FileSystem.fullPath(path) + ":" + stat.dev + ":" + stat.ino + ":" + stat.size + ":" + stat.mtime.getTime() + ":" + stat.ctime.getTime(),
				value = values.get(key);
			if (value == null) {
				value = Sha256.make(File.getBytes(path)).toHex();
				values.set(key, value);
			}
			#if (target.threaded && !eval)
			mutex.release();
			#end
			return value;
		} catch (error:Dynamic) {
			#if (target.threaded && !eval)
			mutex.release();
			#end
			throw error;
		}
	}
}
