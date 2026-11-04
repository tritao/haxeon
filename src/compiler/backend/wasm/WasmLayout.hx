package compiler.backend.wasm;

import compiler.ir.Ir.IrObject;
import compiler.ir.Ir.IrObjectFieldNativeLayout;
import compiler.ir.Ir.IrObjectNativeLayout;
import compiler.ir.Ir.IrEnum;
import compiler.ir.Ir.IrProgram;
import compiler.ir.Ir.IrType;
import compiler.ir.IrInlineValueLayout;
import compiler.ir.IrInlineValueLayout.IrInlineValueSlot;

private typedef WasmInlineSlot = {final path:Array<String>; final presence:Bool; final offset:Int; final size:Int; final signed:Bool;}
private typedef WasmInlineLayout = {final size:Int; final alignment:Int; final slots:Array<WasmInlineSlot>;}

typedef WasmFieldLayout = {
	final name:String;
	final offset:Int;
	final type:IrType;
	final nativeLayout:Null<IrObjectFieldNativeLayout>;
	@:optional final scalarStorage:Null<compiler.ir.Ir.IrScalarStorage>;
}

typedef WasmObjectLayout = {
	final name:String;
	final size:Int;
	final fields:Array<WasmFieldLayout>;
	final nativeLayout:Null<IrObjectNativeLayout>;
}

typedef WasmEnumLayout = {
	final name:String;
	final size:Int;
	final cases:Array<Array<IrType>>;
}

/** One authoritative linear-memory layout for all managed Haxeon values. */
class WasmLayout {
	public final program:IrProgram;

	public static inline final HEADER_SIZE = 8;

	/** Flat objects reserve two words after the type id for an optional owner and byte offset. */
	public static inline final FLAT_HEADER_SIZE = 16;

	public static inline final ARRAY_LENGTH_OFFSET = 8;
	public static inline final ARRAY_CAPACITY_OFFSET = 12;
	public static inline final ARRAY_DATA_POINTER_OFFSET = 16;

	/** Runtime type id of the storage element, the Wasm counterpart of HashLink's `varray.at`. */
	public static inline final ARRAY_ELEMENT_TYPE_OFFSET = 20;

	public static inline final ARRAY_HEADER_SIZE = 24;

	/** Extended header for inline value arrays. Ordinary arrays retain the 24-byte header. */
	public static inline final VALUE_ARRAY_MARKER = 0x56414c41;
	public static inline final VALUE_ARRAY_FORWARD_MARKER = 0x56414657;
	public static inline final VALUE_ARRAY_MARKER_OFFSET = 4;
	public static inline final VALUE_ARRAY_SCALAR_STRIDE_OFFSET = 24;
	public static inline final VALUE_ARRAY_REFERENCE_STRIDE_OFFSET = 28;
	public static inline final VALUE_ARRAY_REFERENCE_DATA_OFFSET = 32;
	public static inline final VALUE_ARRAY_VALIDITY_OFFSET = 36;
	public static inline final VALUE_ARRAY_READ_BRIDGE_OFFSET = 40;
	public static inline final VALUE_ARRAY_WRITE_BRIDGE_OFFSET = 44;
	public static inline final VALUE_ARRAY_ACCEPTS_BRIDGE_OFFSET = 48;
	public static inline final VALUE_ARRAY_FORWARD_HEADER_OFFSET = 52;
	public static inline final VALUE_ARRAY_HEADER_SIZE = 56;
	/** Semantic Iterator<T> type id; iterator objects otherwise share one GC-scanned kind. */
	public static inline final ITERATOR_TYPE_OFFSET = 4;
	public static inline final ITERATOR_ARRAY_OFFSET = 8;
	public static inline final ITERATOR_POSITION_OFFSET = 12;
	public static inline final ITERATOR_SIZE = 16;
	public static inline final DYN_PAYLOAD_OFFSET = 4;
	public static inline final DYN_I32_SIZE = 8;
	public static inline final DYN_I64_SIZE = 16;
	public static inline final DYN_F64_SIZE = 16;
	public static inline final MAP_COUNT_OFFSET = 8;
	public static inline final MAP_CAPACITY_OFFSET = 12;
	public static inline final MAP_ENTRIES_OFFSET = 16;
	public static inline final MAP_HEADER_SIZE = 24;
	public static inline final ROOT_PREVIOUS_FRAME_OFFSET = 0;
	public static inline final ROOT_PREVIOUS_TOP_OFFSET = 4;
	public static inline final ROOT_COUNT_OFFSET = 8;
	public static inline final ROOT_VALUES_OFFSET = 12;
	public static inline final ROOT_RESERVE = 65536;
	public static inline final GC_BLOCK_HEADER_SIZE = 16;
	public static inline final GC_BLOCK_SIZE_OFFSET = 0;
	public static inline final GC_BLOCK_FLAGS_OFFSET = 4;
	public static inline final GC_BLOCK_OWNER_OFFSET = 8;
	public static inline final GC_BLOCK_LINK_OFFSET = 12;
	public static inline final GC_BLOCK_MAGIC = 0x48470000;
	public static inline final GC_BLOCK_MAGIC_MASK = -65536;
	public static inline final GC_BLOCK_ALLOCATED = 1;
	public static inline final GC_BLOCK_MARKED = 2;
	public static inline final GC_BLOCK_SCAN_REFERENCES = 4;
	public static inline final GC_BLOCK_CLEAR_MARKED_MASK = -3;
	public static inline final GC_BLOCK_CLEAR_SCAN_MASK = -5;
	public static inline final GC_MIN_ALLOCATION_BUDGET = 262144;

	// hx_heap in native/wasm/heap.c: wasm32 heap state, owned by the linked C runtime (docs/WASM_LINEAR_RUNTIME.md).
	public static inline final HEAP_STATE_HEAP_START = 0;
	public static inline final HEAP_STATE_HEAP_TOP = 4;
	public static inline final HEAP_STATE_BUDGET = 8;
	public static inline final HEAP_STATE_FLAGS = 20;
	public static inline final HEAP_STATE_ALLOCATION_COUNT = 24;
	public static inline final HEAP_STATE_ALLOCATION_BYTES = 28;
	public static inline final HEAP_STATE_LARGEST_ALLOCATION = 32;
	public static inline final HEAP_STATE_COLLECTION_COUNT = 36;
	public static inline final HEAP_STATE_SIZE = 40 + 128 * 4;
	public static inline final HEAP_FLAG_STRESS = 1;
	public static inline final HEAP_FLAG_STATS = 2;

	public final objects:Map<String, WasmObjectLayout> = [];
	public final enums:Map<String, WasmEnumLayout> = [];
	final logicalObjects:Map<String, IrObject>;
	final valueLayout:WasmValueLayout;

	public function new(program:IrProgram, ?logicalProgram:IrProgram) {
		this.program = program;
		var logical = logicalProgram == null ? program : logicalProgram;
		logicalObjects = [for (object in logical.objects) object.name => object];
		valueLayout = new WasmValueLayout(logical);
		for (object in program.objects)
			buildObjectLayout(object, []);
		for (enumDecl in program.enums)
			enums.set(enumDecl.name, enumLayout(enumDecl));
	}

	public function object(name:String):WasmObjectLayout {
		if (!objects.exists(name))
			throw 'Unknown Wasm object layout "$name"';
		return objects.get(name);
	}

	public function field(objectName:String, fieldName:String):WasmFieldLayout {
		for (field in object(objectName).fields)
			if (field.name == fieldName)
				return field;
		throw 'Unknown field "$objectName.$fieldName" in Wasm layout';
	}

	public function enumType(name:String):WasmEnumLayout {
		if (!enums.exists(name))
			throw 'Unknown Wasm enum layout "$name"';
		return enums.get(name);
	}

	public static function enumLayout(enumDecl:IrEnum):WasmEnumLayout {
		var maxPayload = 0;
		for (constructor in enumDecl.cases) {
			var offset = HEADER_SIZE + 4;
			for (type in constructor.params)
				offset = align(offset, alignmentOf(type)) + sizeOf(type);
			var payload = offset - (HEADER_SIZE + 4);
			if (payload > maxPayload)
				maxPayload = payload;
		}
		return {name: enumDecl.name, size: align(HEADER_SIZE + 4 + maxPayload, 8), cases: [for (constructor in enumDecl.cases) constructor.params]};
	}

	function buildObjectLayout(object:IrObject, visiting:Array<String>):WasmObjectLayout {
		if (objects.exists(object.name))
			return objects.get(object.name);
		if (visiting.indexOf(object.name) >= 0)
			throw 'Cyclic Wasm object inheritance at "${object.name}"';
		var nextVisiting = visiting.copy();
		nextVisiting.push(object.name);
		var nativeLayout = object.nativeLayout;
		if (nativeLayout != null) {
			var fields:Array<WasmFieldLayout> = [
				for (field in object.fields) {
					var native = field.nativeLayout;
					if (native == null) throw 'Flat Wasm object "${object.name}" is missing native field layout "${field.name}"';
					{
						name: field.name,
						offset: FLAT_HEADER_SIZE + native.offset,
						type: field.type,
						nativeLayout: native
					};
				}
			];
			var result:WasmObjectLayout = {
				name: object.name,
				size: align(FLAT_HEADER_SIZE + nativeLayout.size, 8),
				fields: fields,
				nativeLayout: nativeLayout
			};
			objects.set(object.name, result);
			return result;
		}
		var offset = HEADER_SIZE, fields:Array<WasmFieldLayout> = [];
		if (object.base != null) {
			var baseDecl:Null<IrObject> = null;
			for (candidate in program.objects)
				if (candidate.name == object.base)
					baseDecl = candidate;
			if (baseDecl == null)
				throw 'Unknown Wasm base object "${object.base}" for "${object.name}"';
			var base = buildObjectLayout(baseDecl, nextVisiting);
			fields = base.fields.copy();
			offset = base.size;
		}
		var logical = logicalObjects.get(object.name), declared = logical == null ? object.fields : logical.fields;
		for (field in declared) {
			var valueObject = switch field.type { case Obj(name): logicalObjects.get(name); default: null; },
				isInline = valueObject != null && valueObject.isValue,
				physical = isInline ? valueLayout.fields([field]) : [field];
			if (valueObject != null && valueObject.isValue) {
				var shape = inlineLayout(valueObject.name, []), slots = valueLayout.leaves(field.type);
				if (slots.length != shape.slots.length || physical.length != slots.length)
					throw 'Mismatched inline value layout "${object.name}.${field.name}"';
				offset = align(offset, shape.alignment);
				for (index in 0...slots.length) {
					var part = physical[index], slot = slots[index], placement = shape.slots[index];
					if (slot.path.join(".") != placement.path.join(".") || slot.isPresence != placement.presence)
						throw 'Mismatched inline value path "${object.name}.${part.name}"';
					fields.push({name: part.name, offset: offset + placement.offset, type: part.type, nativeLayout: null,
						scalarStorage: {size: placement.size, signed: placement.signed}});
				}
				offset += shape.size;
			} else for (part in physical) {
				offset = align(offset, alignmentOf(part.type));
				var native = part.nativeLayout;
				fields.push({name: part.name, offset: offset, type: part.type, nativeLayout: null,
					scalarStorage: part.scalarStorage != null ? part.scalarStorage : native == null ? null : {size: native.size, signed: native.signed}});
				offset += sizeOf(part.type);
			}
		}
		var result:WasmObjectLayout = {
			name: object.name,
			size: align(offset, 8),
			fields: fields,
			nativeLayout: null
		};
		objects.set(object.name, result);
		return result;
	}

	/** Scalar fields use their declared width; nested Flat records retain all C offsets and padding. */
	function inlineLayout(name:String, visiting:Array<String>):WasmInlineLayout {
		if (visiting.indexOf(name) >= 0) throw 'Cyclic inline Wasm value "$name"';
		var object = logicalObjects.get(name);
		if (object == null || !object.isValue) throw 'Missing inline Wasm value "$name"';
		var nativeLayout = object.nativeLayout;
		if (nativeLayout != null) {
			var slots:Array<WasmInlineSlot> = [];
			for (slot in valueLayout.leaves(Obj(name))) {
				var native = valueLayout.nativeLeaf(Obj(name), slot);
				if (native == null) throw 'Missing native leaf for "$name"';
				slots.push({path: slot.path, presence: slot.isPresence, offset: native.offset, size: native.size, signed: native.signed});
			}
			return {size: nativeLayout.size, alignment: nativeLayout.alignment, slots: slots};
		}
		var offset = 0, maximum = 1, slots:Array<WasmInlineSlot> = [], next = visiting.concat([name]);
		for (field in object.fields) {
			var childName:Null<String> = switch field.type {
				case Obj(child), Nullable(Obj(child)):
					var declaration = logicalObjects.get(child);
					declaration != null && declaration.isValue ? child : null;
				default: null;
			};
			if (childName != null) {
				var optional = switch field.type { case Nullable(_): true; default: false; };
				if (optional) { slots.push({path: [field.name], presence: true, offset: offset++, size: 1, signed: false}); }
				var nested = inlineLayout(childName, next);
				offset = align(offset, nested.alignment);
				if (nested.alignment > maximum) maximum = nested.alignment;
				for (slot in nested.slots) slots.push({path: [field.name].concat(slot.path), presence: slot.presence,
					offset: offset + slot.offset, size: slot.size, signed: slot.signed});
				offset += nested.size;
			} else {
				var storage = compiler.ir.IrFieldStorage.scalar(field), size = storage == null ? sizeOf(field.type) : storage.size,
					alignment = size > 8 ? 8 : size;
				if (alignment < 1) throw 'Invalid inline field "$name.${field.name}"';
				offset = align(offset, alignment);
				if (alignment > maximum) maximum = alignment;
				slots.push({path: [field.name], presence: false, offset: offset, size: size, signed: storage != null && storage.signed});
				offset += size;
			}
		}
		return {size: align(offset, maximum), alignment: maximum, slots: slots};
	}

	public function enumField(typeName:String, constructor:Int, field:Int):{type:IrType, offset:Int} {
		var layout = enumType(typeName);
		if (constructor < 0 || constructor >= layout.cases.length)
			throw 'Unknown constructor $constructor in Wasm enum layout "$typeName"';
		var params = layout.cases[constructor];
		if (field < 0 || field >= params.length)
			throw 'Unknown field $field in Wasm enum constructor $constructor of "$typeName"';
		var offset = HEADER_SIZE + 4;
		for (index in 0...field)
			offset = align(offset, alignmentOf(params[index])) + sizeOf(params[index]);
		offset = align(offset, alignmentOf(params[field]));
		return {type: params[field], offset: offset};
	}

	public static function sizeOf(type:IrType):Int
		return switch type {
			case I64: 8;
			case F32 | F64: 8;
			case Void: 0;
			default: 4;
		};

	public static function arrayStride(type:IrType):Int
		return (switch (type) { case F32: true; default: false; }) || (switch (type) { case F64: true; default: false; }) || (switch (type) { case I64: true; default: false; }) ? 8 : 4;

	public static function arrayAllocationSize(type:IrType, length:Int):Int
		return ARRAY_HEADER_SIZE + arrayStride(type) * length;

	public static inline final STRING_LENGTH_OFFSET = 8;
	public static inline final STRING_DATA_OFFSET = 16;
	public static inline final BYTES_STREAM_LENGTH_OFFSET = 8;
	public static inline final BYTES_STREAM_POSITION_OFFSET = 12;
	public static inline final BYTES_STREAM_CAPACITY_OFFSET = 12;
	public static inline final BYTES_STREAM_DATA_OFFSET = 16;
	public static inline final BYTES_STREAM_ENDIAN_OFFSET = 20;
	public static inline final BYTES_STREAM_SIZE = 24;
	public static inline final BYTES_VIEW_MARKER_OFFSET = 4;
	public static inline final BYTES_VIEW_OWNER_OFFSET = 16;
	public static inline final BYTES_VIEW_DATA_OFFSET = 20;
	public static inline final BYTES_VIEW_ROOTS_OFFSET = 24;
	public static inline final BYTES_VIEW_SIZE = 32;
	public static inline final BYTES_VIEW_MAGIC = 0x48565756;
	public static inline final CLOSURE_FUNCTION_OFFSET = 8;
	public static inline final CLOSURE_RECEIVER_OFFSET = 12;
	public static inline final CLOSURE_SIZE = 16;

	/** Reserved header tag so runtime reflection can distinguish bound closures from objects. */
	public static inline final CLOSURE_TYPE_ID = 0x484C4346;

	public static function alignmentOf(type:IrType):Int
		return (switch (type) { case F32: true; default: false; }) || (switch (type) { case F64: true; default: false; }) || (switch (type) { case I64: true; default: false; }) ? 8 : 4;

	static function align(value:Int, boundary:Int):Int
		return (value + boundary - 1) & ~(boundary - 1);
}
