package runtime.hashlink;

import runtime.memory.RawPtr;

/** HashLink type-size, pointer-classification, and mark-bit policy. */
class HlTypeSemantics {
	/** Return the VM value width for one type record. */
	public static function size(type:RawPtr<HlType>):Int {
		var kind:Int = checkedKind(type);
		return switch kind {
			case 0: 0;
			case 1: 1;
			case 2: 2;
			case 3: 4;
			case 4: 8;
			case 5: 4;
			case 6: 8;
			case 7: sizeof<Bool>();
			case 22: 0;
			case 23: 8;
			case _: pointerSize();
		};
	}

	/** Return the padding needed to align a field at the given byte offset. */
	public static function padStruct(type:RawPtr<HlType>, size:Int):Int {
		if (size < 0)
			throw "HashLink type layout padding requires a non-negative size";
		var kind:Int = checkedKind(type);
		if (kind == 0)
			return 0;
		var alignment = pointerSize();
		switch kind {
			case 1: alignment = alignof<UInt8>();
			case 2: alignment = alignof<UInt16>();
			case 3: alignment = alignof<Int32>();
			case 4 | 23: alignment = alignof<Int64>();
			case 5: alignment = alignof<Float32>();
			case 6: alignment = alignof<Float>();
			case 7: alignment = alignof<Bool>();
			case _:
		}
		return (-size) & (alignment - 1);
	}

	/** Whether the VM stores values of this type in pointer slots. */
	public static function isPointer(type:RawPtr<HlType>):Bool {
		var kind:Int = checkedKind(type);
		return switch kind {
			case 8 | 9 | 10 | 11 | 12 | 13 | 14 | 15 | 16 | 17 | 18 | 19 | 20 | 21 | 22: true;
			case _: false;
		};
	}

	/** Return the native mark-bit storage size for a raw data region. */
	public static function markSize(dataSize:Int):Int {
		if (dataSize < 0)
			throw "HashLink mark-bit size must be non-negative";
		var pointerCount = Std.int((dataSize + pointerSize() - 1) / pointerSize());
		return ((pointerCount + 31) >> 5) * sizeof<Int32>();
	}

	/** Keep the host pointer width as the only machine-sensitive type fact. */
	public static inline function pointerSize():Int
		return HlTypeBridge.native_pointer_size();

	static function checkedKind(type:RawPtr<HlType>):Int {
		if (type.isNull())
			throw "HashLink type metadata pointer must not be null";
		var kind:Int = cast type.ref.kind;
		if (kind < 0 || kind > 23)
			throw 'HashLink type kind $kind is outside the supported range';
		return kind;
	}
}
