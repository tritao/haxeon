package compiler.hl;

import haxe.io.Bytes;
import runtime.hashlink.HlMetadataGeneration;
import runtime.hashlink.HlNativeModule;
import runtime.memory.RawPtr;

/** Owns the HLB model, Haxe metadata, and native module for one loaded module. */
class HlLoadedNativeModule {
	public final code:HlCode;
	public final metadata:HlMetadataGeneration;
	public final nativeModule:HlNativeModule;

	var disposed:Bool = false;

	function new(code:HlCode, metadata:HlMetadataGeneration, nativeModule:HlNativeModule) {
		this.code = code;
		this.metadata = metadata;
		this.nativeModule = nativeModule;
	}

	/** Retire the native module and then release its Haxe-owned metadata arena. */
	public function unload():Bool {
		if (disposed)
			return true;
		if (!nativeModule.unload())
			return false;
		metadata.dispose();
		disposed = true;
		return true;
	}

	/** Invoke a zero-argument i32 function while the loaded module is live. */
	public function callI32(functionIndex:Int):Int {
		if (disposed)
			throw "HashLink loaded module has been unloaded";
		return nativeModule.callI32(functionIndex);
	}

	/** Require both native and Haxe-owned resources to be released. */
	public function close():Void {
		if (!unload())
			throw "HashLink loaded module could not be unloaded";
	}
}

/** Loads HLB through Haxe policy before handing the resulting record to HashLink. */
class HlNativeModuleLoader {
	public static function load(bytes:Bytes, ?functionPointers:Array<RawPtr<UInt8>>, ?flags:Int = 0):HlLoadedNativeModule {
		var code = HlReader.decode(bytes),
			metadata = HlNativeMetadataBuilder.build(code, functionPointers);
		try {
			return new HlLoadedNativeModule(code, metadata, new HlNativeModule(metadata, flags));
		} catch (error:Dynamic) {
			metadata.dispose();
			throw error;
		}
	}
}
