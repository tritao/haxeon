package runtime.hashlink;

import runtime.memory.RawPtr;
import runtime.hashlink.HlNative;
import runtime.hashlink.HashLinkModuleBindings.NativeModuleHlNative;
import runtime.hashlink.HlFunctionTable;

/** Input used to construct one Haxe-owned HashLink native binding descriptor. */
typedef HlNativeDescriptorSpec = {
	final library:RawPtr<UInt8>;
	final name:RawPtr<UInt8>;
	final type:RawPtr<HlType>;
	final findex:Int;
}

/** Owns a contiguous, stable array of HashLink native binding descriptors. */
class HlNativeDescriptorTable {
	public final arena:HlTypeArena;
	final entries:RawPtr<NativeModuleHlNative>;
	final capacity:Int;
	var count:Int = 0;
	var sealed:Bool = false;

	public function new(arena:HlTypeArena, ?capacity:Int = 8) {
		if (arena == null || capacity <= 0)
			throw "HashLink native descriptor capacity must be positive";
		this.arena = arena;
		this.capacity = capacity;
		entries = arena.allocNativeDescriptorArray(capacity);
	}

	/** Append one descriptor and return its stable address. */
	public function add(spec:HlNativeDescriptorSpec):RawPtr<HlNative> {
		if (sealed)
			throw "HashLink native descriptor table is sealed after publication";
		if (spec == null)
			throw "HashLink native descriptor cannot be null";
		if (count >= capacity)
			throw 'HashLink native descriptor table exhausted its $capacity slots';
		if (spec.findex < 0)
			throw "HashLink native descriptor function index must be non-negative";
		var descriptor = entries.offset(count++);
		descriptor.ref.library = spec.library;
		descriptor.ref.name = spec.name;
		descriptor.ref.type = spec.type;
		descriptor.ref.findex = cast spec.findex;
		return descriptor;
	}

	@:allow(runtime.hashlink.HlMetadataGeneration)
	function seal():Void {
		sealed = true;
	}

	public inline function pointer():RawPtr<NativeModuleHlNative>
		return entries;

	public inline function length():Int
		return count;

	public inline function capacityOf():Int
		return capacity;

	/** Validate native binding indices and signatures against module dispatch slots. */
	public function validate(functions:HlFunctionTable):Void {
		if (functions == null)
			throw "HashLink native descriptors require a module function table";
		for (index in 0...count) {
			var descriptor = entries.offset(index), findex:Int = cast descriptor.ref.findex;
			if (findex < 0 || findex >= functions.length())
				throw 'HashLink native descriptor $index references dispatch slot $findex outside the module table';
			if (descriptor.ref.type.isNull())
				throw 'HashLink native descriptor $index has no signature type';
			if (functions.typeAt(findex) != descriptor.ref.type)
				throw 'HashLink native descriptor $index signature disagrees with dispatch slot $findex';
			for (previous in 0...index) {
				var previousFindex:Int = cast entries.offset(previous).ref.findex;
				if (previousFindex == findex)
					throw 'HashLink native descriptor table contains duplicate dispatch slot $findex';
			}
		}
	}

	public function get(index:Int):RawPtr<NativeModuleHlNative> {
		if (index < 0 || index >= count)
			throw 'HashLink native descriptor index $index is outside 0...$count';
		return entries.offset(index);
	}
}
