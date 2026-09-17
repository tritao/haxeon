package runtime.hashlink;

import runtime.memory.RawPtr;
import runtime.hashlink.HlFunction;
import runtime.hashlink.HashLinkModuleBindings.NativeModuleHlFunction;
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
	final entries:RawPtr<NativeModuleHlFunction>;
	final capacity:Int;
	var count:Int = 0;
	var sealed:Bool = false;

	public function new(arena:HlTypeArena, ?capacity:Int = 8) {
		if (arena == null || capacity <= 0)
			throw "HashLink function descriptor capacity must be positive";
		this.arena = arena;
		this.capacity = capacity;
		entries = arena.allocFunctionArray(capacity);
	}

	/** Append one descriptor and return its stable address. */
	public function add(spec:HlFunctionDescriptorSpec):RawPtr<HlFunction> {
		if (sealed)
			throw "HashLink function descriptor table is sealed after publication";
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

	@:allow(runtime.hashlink.HlMetadataGeneration)
	function seal():Void {
		sealed = true;
	}

	public inline function pointer():RawPtr<NativeModuleHlFunction>
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

	/** Validate one descriptor's native opcode storage and opcode identities. */
	public function validateCodeAt(index:Int):Int {
		var descriptor = get(index), nregs:Int = cast descriptor.ref.nregs, nops:Int = cast descriptor.ref.nops;
		if (nregs < 0 || (nregs > 0 && descriptor.ref.regs.isNull()))
			throw 'HashLink function descriptor $index contains an incomplete register array';
		if (nops < 0 || (nops > 0 && descriptor.ref.ops.isNull()))
			throw 'HashLink function descriptor $index contains an incomplete opcode array';
		for (opcodeIndex in 0...nops) {
			var opcode:Int = cast descriptor.ref.ops.offset(opcodeIndex).ref.op;
			if (opcode < 0 || opcode >= HlOpcodeLimit.LAST_OPCODE)
				throw 'HashLink function descriptor $index contains an invalid opcode';
		}
		return nops;
	}

	/** Validate one descriptor's source locations and debug-assignment storage. */
	public function validateDebugAt(index:Int, debugFileCount:Int):Int {
		var descriptor = get(index), nops:Int = cast descriptor.ref.nops, nassigns:Int = cast descriptor.ref.nassigns;
		if (debugFileCount < 0)
			throw "HashLink function debug validation requires a non-negative file count";
		if (!descriptor.ref.debug.isNull()) {
			if (debugFileCount == 0)
				throw "HashLink function debug metadata has no file table";
			for (opcodeIndex in 0...nops) {
				var file:Int = cast descriptor.ref.debug.offset(opcodeIndex * 2).load(), line:Int = cast descriptor.ref.debug.offset(opcodeIndex * 2 + 1).load();
				if (file < 0 || file >= debugFileCount || line < 1)
					throw "HashLink function debug metadata contains an invalid location";
			}
		}
		if (nassigns < 0 || (nassigns > 0 && descriptor.ref.assigns.isNull()))
			throw 'HashLink function descriptor $index contains an incomplete assignment table';
		for (assignmentIndex in 0...nassigns) {
			var position:Int = cast descriptor.ref.assigns.offset(assignmentIndex * 3 + 1).load(), scopeEnd:Int = cast descriptor.ref.assigns.offset(assignmentIndex * 3 + 2).load();
			if (position < -1 || scopeEnd < -1)
				throw "HashLink function debug metadata contains an invalid assignment range";
		}
		return nassigns;
	}

	public function get(index:Int):RawPtr<NativeModuleHlFunction> {
		if (index < 0 || index >= count)
			throw 'HashLink function descriptor index $index is outside 0...$count';
		return entries.offset(index);
	}
}
