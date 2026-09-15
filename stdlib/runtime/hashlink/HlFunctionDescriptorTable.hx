package runtime.hashlink;

import runtime.memory.RawPtr;
import runtime.hashlink.HlFunction;
import runtime.hashlink.HlOpcode;

/** Input used to construct one Haxe-owned HashLink function descriptor. */
typedef HlFunctionDescriptorSpec = {
	final findex:Int;
	final nregs:Int;
	final nops:Int;
	final reference:Int;
	final nassigns:Int;
	final type:RawPtr<HlType>;
	final regs:RawPtr<RawPtr<HlType>>;
	final ops:RawPtr<HlOpcode>;
	final debug:RawPtr<Int32>;
	final assigns:RawPtr<Int32>;
	final object:RawPtr<HlTypeObject>;
	final fieldName:RawPtr<UInt16>;
	final fieldReference:RawPtr<HlFunction>;
}

/** Owns a contiguous, stable array of HashLink bytecode function descriptors. */
class HlFunctionDescriptorTable {
	public final arena:HlTypeArena;
	final entries:RawPtr<HlFunction>;
	final capacity:Int;
	var count:Int = 0;

	public function new(arena:HlTypeArena, ?capacity:Int = 8) {
		if (arena == null || capacity <= 0)
			throw "HashLink function descriptor capacity must be positive";
		this.arena = arena;
		this.capacity = capacity;
		entries = arena.allocFunctionArray(capacity);
	}

	/** Append one descriptor and return its stable address. */
	public function add(spec:HlFunctionDescriptorSpec):RawPtr<HlFunction> {
		if (spec == null)
			throw "HashLink function descriptor cannot be null";
		if (count >= capacity)
			throw 'HashLink function descriptor table exhausted its $capacity slots';
		if (!spec.fieldName.isNull() && !spec.fieldReference.isNull())
			throw "HashLink function descriptor field cannot contain both a name and a reference";
		var descriptor = entries.offset(count++);
		descriptor.ref.findex = cast spec.findex;
		descriptor.ref.nregs = cast spec.nregs;
		descriptor.ref.nops = cast spec.nops;
		descriptor.ref.reference = cast spec.reference;
		descriptor.ref.nassigns = cast spec.nassigns;
		descriptor.ref.type = spec.type;
		descriptor.ref.regs = spec.regs;
		descriptor.ref.ops = spec.ops;
		descriptor.ref.debug = spec.debug;
		descriptor.ref.assigns = spec.assigns;
		descriptor.ref.object = spec.object;
		if (!spec.fieldReference.isNull())
			descriptor.ref.field.ref.reference = spec.fieldReference;
		else
			descriptor.ref.field.ref.name = spec.fieldName;
		return descriptor;
	}

	public inline function pointer():RawPtr<HlFunction>
		return entries;

	public inline function length():Int
		return count;

	public inline function capacityOf():Int
		return capacity;

	/** Validate descriptor indices and signatures against module dispatch slots. */
	public function validate(functions:HlFunctionTable):Void {
		if (functions == null)
			throw "HashLink function descriptors require a module function table";
		for (index in 0...count) {
			var descriptor = entries.offset(index), findex:Int = cast descriptor.ref.findex,
				nregs:Int = cast descriptor.ref.nregs, nops:Int = cast descriptor.ref.nops, nassigns:Int = cast descriptor.ref.nassigns;
			if (findex < 0 || findex >= functions.length())
				throw 'HashLink function descriptor $index references dispatch slot $findex outside the module table';
			if (nregs < 0 || nops < 0 || nassigns < 0)
				throw 'HashLink function descriptor $index contains a negative storage count';
			if (descriptor.ref.type.isNull())
				throw 'HashLink function descriptor $index has no signature type';
			if (functions.typeAt(findex) != descriptor.ref.type)
				throw 'HashLink function descriptor $index signature disagrees with dispatch slot $findex';
			for (previous in 0...index) {
				var previousFindex:Int = cast entries.offset(previous).ref.findex;
				if (previousFindex == findex)
					throw 'HashLink function descriptor table contains duplicate dispatch slot $findex';
			}
		}
	}

	public function get(index:Int):RawPtr<HlFunction> {
		if (index < 0 || index >= count)
			throw 'HashLink function descriptor index $index is outside 0...$count';
		return entries.offset(index);
	}
}
