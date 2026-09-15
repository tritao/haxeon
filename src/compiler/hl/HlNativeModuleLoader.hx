package compiler.hl;

import haxe.io.Bytes;
import compiler.hl.persistence.HlRuntimeIdentity;
import compiler.hl.persistence.HlRuntimeIdentity.HlRuntimeManifest;
import runtime.hashlink.HlMetadataGeneration;
import runtime.hashlink.HlNativeModule;
import runtime.hashlink.HlRuntimeModule;
import runtime.memory.RawPtr;

/** Owns the HLB model, Haxe metadata, and native module for one loaded module. */
class HlLoadedNativeModule {
	public final module:HlModule;
	public final code:HlCode;
	public final metadata:HlMetadataGeneration;
	public final nativeModule:HlNativeModule;

	var disposed:Bool = false;

	function new(module:HlModule, metadata:HlMetadataGeneration, nativeModule:HlNativeModule) {
		this.module = module;
		this.code = module.code;
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

/** Owns one Haxe-built metadata generation loaded by the runtime wrapper. */
class HlLoadedRuntimeModule {
	public final module:HlModule;
	public final code:HlCode;
	public final identity:HlRuntimeManifest;
	public final metadata:HlMetadataGeneration;
	public final nativeModule:HlRuntimeModule;

	var disposed:Bool = false;

	function new(module:HlModule, identity:HlRuntimeManifest, metadata:HlMetadataGeneration, nativeModule:HlRuntimeModule) {
		this.module = module;
		this.code = module.code;
		this.identity = identity;
		this.metadata = metadata;
		this.nativeModule = nativeModule;
	}

	/** Retire the runtime wrapper and then release its Haxe-owned metadata arena. */
	public function unload():Bool {
		if (disposed)
			return true;
		if (!nativeModule.unload())
			return false;
		metadata.dispose();
		disposed = true;
		return true;
	}

	/** Invoke a stable zero-argument i32 function while the loaded module is live. */
	public function callI32(stableId:Int):Int {
		if (disposed)
			throw "HashLink loaded runtime module has been unloaded";
		return nativeModule.callI32(stableId);
	}

	/** Execute the manifest initializer through the Haxe-owned runtime policy. */
	@:allow(compiler.hl.HlNativeModuleLoader)
	function initialize():Void {
		if (identity.initializerSlot < 0)
			return;
		for (entry in identity.entries)
			if (entry.functionIndex == identity.initializerSlot) {
				if (!HlRuntimeCallPolicy.validFunction(module, identity, entry.stableId, 1))
					throw "HLI initializer must reference a zero-argument void function";
				nativeModule.callVoid(entry.stableId);
				return;
			}
		throw "HLI initializer slot is not represented by the identity table";
	}
}

/** Loads HLB through Haxe policy before handing the resulting record to HashLink. */
class HlNativeModuleLoader {
	public static function load(bytes:Bytes, ?functionPointers:Array<RawPtr<UInt8>>, ?flags:Int = 0):HlLoadedNativeModule {
		var module = HlModule.decode(bytes),
			metadata = HlNativeMetadataBuilder.buildModule(module, functionPointers);
		try {
			return new HlLoadedNativeModule(module, metadata, new HlNativeModule(metadata, flags));
		} catch (error:Dynamic) {
			metadata.dispose();
			throw error;
		}
	}

	/** Build Haxe-owned metadata, then hand its complete code record to HashLink. */
	public static function loadRuntime(bytes:Bytes, identity:Bytes):HlLoadedRuntimeModule {
		var module = HlModule.decode(bytes),
			identityModel = validateIdentity(HlRuntimeIdentity.decode(identity), module),
			metadata = HlNativeMetadataBuilder.buildModule(module);
		var loaded:Null<HlLoadedRuntimeModule> = null;
		try {
			loaded = new HlLoadedRuntimeModule(module, identityModel, metadata, new HlRuntimeModule(metadata, bytes, identity));
			loaded.initialize();
			return loaded;
		} catch (error:Dynamic) {
			if (loaded == null)
				metadata.dispose();
			else if (!loaded.unload())
				throw "HashLink external runtime module could not be unloaded after initialization failure";
			throw error;
		}
	}

	static function validateIdentity(identity:HlRuntimeManifest, model:HlModule):HlRuntimeManifest {
		var initializerEntry = identity.initializerSlot < 0;
		for (entry in identity.entries)
			if (model.functionAt(entry.functionIndex) == null)
				throw 'HLI identity references missing dispatch slot ${entry.functionIndex}';
			else if (entry.functionIndex == identity.initializerSlot)
				initializerEntry = true;
		if (!initializerEntry)
			throw 'HLI initializer references a slot absent from the identity table';
		return identity;
	}
}
