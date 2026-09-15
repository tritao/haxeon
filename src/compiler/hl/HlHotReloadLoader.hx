package compiler.hl;

import haxe.io.Bytes;
import runtime.hashlink.HlFunctionVersionTable;
import runtime.hashlink.HlHotReloadState;
import runtime.hashlink.HlHotReloadState.HlHotReloadGeneration;
import runtime.hashlink.HlHotReloadTransaction;
import runtime.hashlink.HlMetadataGeneration;
import runtime.memory.RawPtr;

/** Owns a decoded HLB module until its hot-reload transaction is resolved. */
class HlStagedHotReloadModule {
	public final module:HlModule;
	public final code:HlCode;
	public final metadata:HlMetadataGeneration;
	public final functions:HlFunctionVersionTable;
	public final transaction:HlHotReloadTransaction;

	function new(module:HlModule, metadata:HlMetadataGeneration, functions:HlFunctionVersionTable, transaction:HlHotReloadTransaction) {
		this.module = module;
		this.code = module.code;
		this.metadata = metadata;
		this.functions = functions;
		this.transaction = transaction;
	}

	/** Publish the candidate through the normal Haxe metadata policy. */
	public function commit():HlHotReloadGeneration
		return transaction.commit();

	/** Initialize and publish the candidate through the native module boundary. */
	public function commitNative(?flags:Int = 0):HlHotReloadGeneration
		return transaction.commitNative(flags);

	/** Release the candidate when it will not be published. */
	public function rollback():Void
		transaction.rollback();
}

/** Decodes HLB and stages Haxe-owned metadata before hot-reload policy runs. */
class HlHotReloadLoader {
	public static function stage(state:HlHotReloadState, bytes:Bytes, ?functionPointers:Array<RawPtr<UInt8>>,
			?structuralReload:Bool = false):HlStagedHotReloadModule {
		if (state == null)
			throw "HashLink hot-reload loading requires a state owner";
		var module = HlModule.decode(bytes),
			metadata = HlNativeMetadataBuilder.buildModule(module, functionPointers);
		try {
			var functions = new HlFunctionVersionTable(functionEntries(module, metadata));
			return new HlStagedHotReloadModule(module, metadata, functions, state.stage(metadata, functions, structuralReload));
		} catch (error:Dynamic) {
			metadata.dispose();
			throw error;
		}
	}

	static function functionEntries(module:HlModule, metadata:HlMetadataGeneration):Array<runtime.hashlink.HlFunctionVersionTable.HlFunctionVersionEntry> {
		var result:Array<runtime.hashlink.HlFunctionVersionTable.HlFunctionVersionEntry> = [];
		for (fn in module.code.functions) {
			result.push({
				stableId: module.stableIdAt(fn.functionIndex),
				slot: fn.functionIndex,
				typeIndex: fn.type,
				entrypoint: metadata.functionPointer(fn.functionIndex)
			});
		}
		return result;
	}
}
