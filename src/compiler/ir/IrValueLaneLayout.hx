package compiler.ir;

import compiler.ir.Ir.IrObject;
import compiler.ir.Ir.IrScalarStorage;
import compiler.ir.Ir.IrType;

/** A few native handles have different physical representations across the supported runtimes. */
enum IrValueLaneTarget {
	HashLink;
	Wasm32;
	WasmGc;
}

/** A leaf of an inline value, addressed within one element of a collection's two lanes. */
typedef IrValueLaneSlot = {
	final path:Array<String>;
	final type:IrType;
	final isPresence:Bool;
	/** This leaf is the non-null payload of a nullable primitive. */
	final nullablePayload:Bool;
	/** Scalar word or reference slot, according to `isReference`. */
	final index:Int;
	final isReference:Bool;
	/** Offset and width in bits within the first scalar word of element zero; zero for references. */
	final bitOffset:Int;
	final bitWidth:Int;
	final signed:Bool;
}

typedef IrValueLaneShape = {
	final scalarWordBits:Int;
	/** Bits between element starts. Flat records retain their C stride, which can end within a word. */
	final scalarStrideBits:Int;
	final scalarWords:Int;
	final references:Int;
	final cLayout:Bool;
	final slots:Array<IrValueLaneSlot>;
}

private typedef LaneLeaf = {
	final path:Array<String>;
	final type:IrType;
	final isPresence:Bool;
	final nullablePayload:Bool;
	final scalar:Null<{bits:Int, signed:Bool}>;
	/** Bit offset from the beginning of the containing Flat record. */
	final flatOffset:Int;
}

private enum LanePart {
	Leaf(value:LaneLeaf);
	Flat(size:Int, alignment:Int, leaves:Array<LaneLeaf>);
}

/**
 * Deterministic scalar/reference layout shared by inline collections and their backends. Managed references occupy a
 * separate lane. A Flat value occupies its exact C byte layout, including padding; this also holds for a Flat value
 * nested in a managed struct. Packed scalar fields and C records can cross a word boundary at later element indices.
 */
class IrValueLaneLayout {
	final objects:IrObjectTable;
	final pointerBits:Int;
	final target:IrValueLaneTarget;

	public function new(objects:IrObjectTable, pointerBits:Int, target:IrValueLaneTarget) {
		if (pointerBits != 32 && pointerBits != 64) throw 'Unsupported pointer width $pointerBits';
		this.objects = objects;
		this.pointerBits = pointerBits;
		this.target = target;
	}

	public function shape(type:IrType):IrValueLaneShape {
		var parts:Array<LanePart> = [];
		append(type, [], [], null, parts);
		var wordBits = 32;
		for (part in parts)
			switch part {
				case Leaf(leaf): if (leaf.scalar != null && leaf.scalar.bits > 32) wordBits = 64;
				case Flat(_, _, leaves):
					for (leaf in leaves) if (leaf.scalar != null && leaf.scalar.bits > 32) wordBits = 64;
			}
		var slots:Array<IrValueLaneSlot> = [], scalarBits = 0, references = 0;
		for (part in parts)
			switch part {
				case Leaf(leaf):
					var scalar = leaf.scalar;
					if (scalar == null) {
						slots.push({path: leaf.path, type: leaf.type, isPresence: leaf.isPresence, nullablePayload: leaf.nullablePayload,
							index: references++, isReference: true, bitOffset: 0, bitWidth: 0, signed: false});
					} else {
						var offset = scalarBits % wordBits;
						if (offset + scalar.bits > wordBits) scalarBits += wordBits - offset;
						slots.push(scalarSlot(leaf, scalarBits, wordBits));
						scalarBits += scalar.bits;
					}
				case Flat(size, alignment, leaves):
					var aligned = align(scalarBits, alignment * 8);
					for (leaf in leaves) slots.push(scalarSlot(leaf, aligned + leaf.flatOffset, wordBits));
					scalarBits = aligned + size * 8;
			}
		var cLayout = switch type { case Obj(name): isFlat(name); default: false; };
		var stride = cLayout ? scalarBits : align(scalarBits, wordBits);
		return {scalarWordBits: wordBits, scalarStrideBits: stride, scalarWords: Std.int((stride + wordBits - 1) / wordBits),
			references: references, cLayout: cLayout, slots: slots};
	}

	/** Capacity uses the bit stride, not rounded words per element: Flat records can share a word. */
	public static function scalarStorageWords(shape:IrValueLaneShape, length:Int):Int {
		if (length < 0) throw 'Negative value array capacity';
		var words = Math.fceil((length * 1.0 * shape.scalarStrideBits) / shape.scalarWordBits);
		if (words > 0x7fffffff) throw 'Value array scalar lane is too large';
		return Std.int(words);
	}

	public static function referenceStorageSlots(shape:IrValueLaneShape, length:Int):Int {
		if (length < 0) throw 'Negative value array capacity';
		var slots = length * 1.0 * shape.references;
		if (slots > 0x7fffffff) throw 'Value array reference lane is too large';
		return Std.int(slots);
	}

	function append(type:IrType, path:Array<String>, visiting:Array<String>, storage:Null<IrScalarStorage>, parts:Array<LanePart>):Void {
		switch type {
			case Nullable(Obj(name)) if (isValue(name)):
				parts.push(Leaf(presence(path)));
				append(Obj(name), path, visiting, null, parts);
			case Obj(name) if (isValue(name)):
				if (visiting.indexOf(name) >= 0) throw 'Value layout contains a by-value cycle at "$name"';
				var object = requireValue(name), next = visiting.concat([name]), nativeLayout = object.nativeLayout;
				if (nativeLayout != null) {
					var leaves:Array<LaneLeaf> = [];
					appendFlat(object, path, visiting, 0, leaves);
					parts.push(Flat(nativeLayout.size, nativeLayout.alignment, leaves));
				} else
					for (field in object.fields)
						append(field.type, path.concat([field.name]), next,
							field.nullableScalarStorage == null ? IrFieldStorage.scalar(field) : field.nullableScalarStorage, parts);
			case Nullable(inner) if (primitive(inner)):
				parts.push(Leaf(presence(path)));
				parts.push(Leaf({path: path, type: inner, isPresence: false, nullablePayload: true, scalar: scalar(inner, storage), flatOffset: 0}));
			case Void: throw 'Void cannot be stored in a value lane';
			default:
				parts.push(Leaf({path: path, type: type, isPresence: false, nullablePayload: false, scalar: scalar(type, storage), flatOffset: 0}));
		}
	}

	/** Preserve every nested C offset; no reference is permitted in a Flat record. */
	function appendFlat(object:IrObject, path:Array<String>, visiting:Array<String>, base:Int, leaves:Array<LaneLeaf>):Void {
		if (visiting.indexOf(object.name) >= 0) throw 'Value layout contains a by-value cycle at "${object.name}"';
		var next = visiting.concat([object.name]);
		for (field in object.fields) {
			var native = field.nativeLayout;
			if (native == null) throw 'Missing Flat field layout for "${object.name}.${field.name}"';
			var fieldPath = path.concat([field.name]), offset = base + native.offset;
			if (native.inlineRecord) {
				var child = switch field.type { case Obj(name): requireValue(name); default: throw 'Invalid Flat field "${object.name}.${field.name}"'; };
				if (child.nativeLayout == null) throw 'Missing Flat layout for "${child.name}"';
				appendFlat(child, fieldPath, next, offset, leaves);
			} else {
				var representation = scalar(field.type, IrFieldStorage.scalar(field));
				if (representation == null) throw 'Flat field "${object.name}.${field.name}" is not scalar';
				leaves.push({path: fieldPath, type: field.type, isPresence: false, nullablePayload: false, scalar: representation, flatOffset: offset * 8});
			}
		}
	}

	static function presence(path:Array<String>):LaneLeaf
		return {path: path, type: Bool, isPresence: true, nullablePayload: false, scalar: {bits: 8, signed: false}, flatOffset: 0};

	static function scalarSlot(leaf:LaneLeaf, start:Int, wordBits:Int):IrValueLaneSlot {
		var scalar = leaf.scalar;
		if (scalar == null) throw 'Reference leaf cannot occupy the scalar lane';
		return {path: leaf.path, type: leaf.type, isPresence: leaf.isPresence, nullablePayload: leaf.nullablePayload,
			index: Std.int(start / wordBits), isReference: false, bitOffset: start % wordBits, bitWidth: scalar.bits, signed: scalar.signed};
	}

	static function align(bits:Int, alignment:Int):Int {
		if (alignment <= 0) throw 'Invalid lane alignment $alignment';
		var remainder = bits % alignment;
		return remainder == 0 ? bits : bits + alignment - remainder;
	}

	function isValue(name:String):Bool {
		var object = objects.get(name);
		return object != null && object.isValue;
	}

	function isFlat(name:String):Bool {
		var object = objects.get(name);
		return object != null && object.isValue && object.nativeLayout != null;
	}

	function requireValue(name:String):IrObject {
		var object = objects.get(name);
		if (object == null || !object.isValue) throw 'Missing value object "$name"';
		return object;
	}

	static function primitive(type:IrType):Bool return switch type {
		case I32 | I64 | Bool | F32 | F64: true;
		default: false;
	};

	function scalar(type:IrType, storage:Null<IrScalarStorage>):Null<{bits:Int, signed:Bool}> {
		var bits = switch type {
			case Bool: 8;
			case I32 | F32: 32;
			case I64 | F64: 64;
			case RawPtr: pointerBits;
			case TypeRef: target == HashLink ? pointerBits : 32;
			case Abstract("native_callback") if (target != HashLink): 32;
			default: return null;
		};
		if (storage != null && (type == I32 || type == I64)) bits = storage.size * 8;
		return {bits: bits, signed: storage != null && storage.signed};
	}
}
