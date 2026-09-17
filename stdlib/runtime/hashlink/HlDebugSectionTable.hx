package runtime.hashlink;

import runtime.memory.RawPtr;
import runtime.hashlink.HashLinkModuleBindings.NativeModuleHlDebugSection;

/** Owns a contiguous, stable array of HashLink module debug sections. */
class HlDebugSectionTable {
	public final arena:HlTypeArena;
	final entries:RawPtr<NativeModuleHlDebugSection>;
	final capacity:Int;
	var count:Int = 0;

	public function new(arena:HlTypeArena, ?capacity:Int = 8) {
		if (arena == null || capacity <= 0)
			throw "HashLink debug section capacity must be positive";
		this.arena = arena;
		this.capacity = capacity;
		entries = arena.allocDebugSectionArray(capacity);
	}

	/** Append one immutable debug section and copy its payload into the arena. */
	public function add(spec:HlDebugSectionSpec):RawPtr<NativeModuleHlDebugSection> {
		if (spec == null || spec.payload == null)
			throw "HashLink debug section requires a payload";
		if (count >= capacity)
			throw 'HashLink debug section table exhausted its $capacity slots';
		if (spec.kind <= 0 || spec.version <= 0 || spec.flags < 0)
			throw "HashLink debug section has invalid metadata";
		var payload = spec.payload,
			data:RawPtr<UInt8> = payload.length == 0 ? RawPtr.nullPtr() : arena.allocUInt8Array(payload.length),
			section = entries.offset(count++);
		for (index in 0...payload.length)
			data.offset(index).store(cast payload.get(index));
		section.ref.kind = cast spec.kind;
		section.ref.version = cast spec.version;
		section.ref.flags = cast spec.flags;
		section.ref.size = cast payload.length;
		section.ref.data = data;
		return section;
	}

	public inline function pointer():RawPtr<NativeModuleHlDebugSection>
		return entries;

	public inline function length():Int
		return count;

	public inline function capacityOf():Int
		return capacity;

	/** Validate section headers and payload storage before native publication. */
	public function validate():Int {
		for (index in 0...count) {
			var section = entries.offset(index), kind:Int = cast section.ref.kind, version:Int = cast section.ref.version,
				flags:Int = cast section.ref.flags, size:Int = cast section.ref.size;
			if (kind <= 0 || version <= 0 || flags < 0 || size < 0 || (size > 0 && section.ref.data.isNull()))
				throw 'HashLink debug section $index contains invalid storage metadata';
		}
		return count;
	}

	public function get(index:Int):RawPtr<NativeModuleHlDebugSection> {
		if (index < 0 || index >= count)
			throw 'HashLink debug section index $index is outside 0...$count';
		return entries.offset(index);
	}
}
