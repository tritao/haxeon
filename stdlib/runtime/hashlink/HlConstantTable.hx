package runtime.hashlink;

import runtime.memory.RawPtr;
import runtime.hashlink.HashLinkModuleBindings.NativeModuleHlConstant;

/** Input used to construct one Haxe-owned HashLink constant descriptor. */
typedef HlConstantDescriptorSpec = {
	final global:Int;
	final nfields:Int;
	final fields:RawPtr<Int32>;
}

/** Owns a contiguous, stable array of HashLink global constant descriptors. */
class HlConstantTable {
	public final arena:HlTypeArena;
	final entries:RawPtr<NativeModuleHlConstant>;
	final capacity:Int;
	var count:Int = 0;

	public function new(arena:HlTypeArena, ?capacity:Int = 8) {
		if (arena == null || capacity <= 0)
			throw "HashLink constant descriptor capacity must be positive";
		this.arena = arena;
		this.capacity = capacity;
		entries = arena.allocConstantArray(capacity);
	}

	/** Append one constant descriptor and return its stable address. */
	public function add(spec:HlConstantDescriptorSpec):RawPtr<NativeModuleHlConstant> {
		if (spec == null)
			throw "HashLink constant descriptor cannot be null";
		if (count >= capacity)
			throw 'HashLink constant descriptor table exhausted its $capacity slots';
		if (spec.global < 0 || spec.nfields < 0 || spec.nfields > 0 && spec.fields.isNull())
			throw "HashLink constant descriptor contains invalid storage metadata";
		var descriptor = entries.offset(count++);
		descriptor.ref.global = cast spec.global;
		descriptor.ref.nfields = cast spec.nfields;
		descriptor.ref.fields = spec.fields;
		return descriptor;
	}

	public inline function pointer():RawPtr<NativeModuleHlConstant>
		return entries;

	public inline function length():Int
		return count;

	public inline function capacityOf():Int
		return capacity;

	/** Apply one native materialization operation to every validated descriptor. */
	public function initialize(initializer:Int->Bool):Void {
		if (initializer == null)
			throw "HashLink constant initialization requires a native operation";
		for (index in 0...count)
			if (!initializer(index))
				throw 'HashLink native constant initialization failed at index $index';
	}

	/** Validate global indices and field storage against a module global table. */
	public function validate(globalCount:Int):Int {
		if (globalCount < 0)
			throw "HashLink constant descriptors require a non-negative global count";
		for (index in 0...count) {
			var descriptor = entries.offset(index), global:Int = cast descriptor.ref.global, nfields:Int = cast descriptor.ref.nfields;
			if (global < 0 || global >= globalCount)
				throw 'HashLink constant descriptor $index references global $global outside the module table';
			if (nfields < 0 || nfields > 0 && descriptor.ref.fields.isNull())
				throw 'HashLink constant descriptor $index contains incomplete field storage';
			for (fieldIndex in 0...nfields) {
				var field:Int = cast descriptor.ref.fields.offset(fieldIndex).load();
				if (field < 0)
					throw 'HashLink constant descriptor $index contains an invalid field index';
			}
		}
		return count;
	}

	public function get(index:Int):RawPtr<NativeModuleHlConstant> {
		if (index < 0 || index >= count)
			throw 'HashLink constant descriptor index $index is outside 0...$count';
		return entries.offset(index);
	}
}
