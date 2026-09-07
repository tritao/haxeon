package compiler.types;

import haxe.io.Bytes;
import haxe.io.BytesInput;
import haxe.io.BytesOutput;

/** Persistent runtime-independent identity of a declared source type. */
abstract StableTypeId(Int) from Int to Int {}

/** Persistent identity of a field within its declaring type. */
abstract StableFieldId(Int) from Int to Int {}

/** Persistent identity of a method within its declaring type. */
abstract StableMethodId(Int) from Int to Int {}

/** Name and canonical semantic type supplied when declaring a field layout. */
typedef DeclaredField = {final name:String; final type:String;}

/** Name and canonical signature supplied when declaring a method. */
typedef DeclaredMethod = {final name:String; final signature:String;}

/** Stable field identity and its current physical layout slot. */
class TypeField {
	public final id:StableFieldId;
	public final name:String;
	public final type:String;
	public final slot:Int;

	public function new(id, name, type, slot) {
		this.id = id;
		this.name = name;
		this.type = type;
		this.slot = slot;
	}
}

/** Stable method identity and its current semantic signature. */
class TypeMethod {
	public final id:StableMethodId;
	public final name:String;
	public final signature:String;

	public function new(id, name, signature) {
		this.id = id;
		this.name = name;
		this.signature = signature;
	}
}

/** Current source-level layout and identities of a declared class. */
class TypeDescriptor {
	public final id:StableTypeId;
	public final name:String;
	public final isValue:Bool;
	public final base:Null<String>;
	public final fields:Array<TypeField>;
	public final methods:Array<TypeMethod>;

	public function new(id, name, base, fields, methods, isValue = false) {
		this.id = id;
		this.name = name;
		this.isValue = isValue;
		this.base = base;
		this.fields = fields;
		this.methods = methods;
	}
}

/** Compatibility of a class declaration with its previously registered layout. */
enum TypeCompatibility {
	NewType;
	Compatible;
	MethodSignatureChanged;
	LayoutChanged;
	BaseChanged;
}

/** Registered descriptor paired with its compatibility classification. */
typedef TypeDeclarationResult = {
	final descriptor:TypeDescriptor;
	final compatibility:TypeCompatibility;
}

/** Stable source-level identities, independent of transient HashLink indices. */
class TypeRegistry {
	static inline final MAGIC = "TID";
	static inline final VERSION = 1;

	final ids:Map<String, Int> = [];
	final descriptors:Map<String, TypeDescriptor> = [];
	var nextId:Int = 1;

	public function new(?state:Bytes) {
		if (state != null)
			importState(state);
	}

	public function copy():TypeRegistry {
		var result = new TypeRegistry();
		for (name => id in ids)
			result.ids.set(name, id);
		for (name => descriptor in descriptors)
			result.descriptors.set(name, descriptor);
		result.nextId = nextId;
		return result;
	}

	public function declareClass(name:String, base:Null<String>, fields:Array<DeclaredField>, methods:Array<DeclaredMethod>,
			isValue = false):TypeDeclarationResult {
		var typeId:StableTypeId = idFor("type:" + name);
		var typeFields = [];
		for (slot in 0...fields.length) {
			var field = fields[slot];
			typeFields.push(new TypeField(idFor("field:" + name + ":" + field.name), field.name, field.type, slot));
		}
		var typeMethods = [];
		for (method in methods)
			typeMethods.push(new TypeMethod(idFor("method:" + name + ":" + method.name), method.name, method.signature));
		var descriptor = new TypeDescriptor(typeId, name, base, typeFields, typeMethods, isValue),
			previous = descriptors.get(name);
		descriptors.set(name, descriptor);
		return {descriptor: descriptor, compatibility: classify(previous, descriptor)};
	}

	public function get(name:String):Null<TypeDescriptor>
		return descriptors.get(name);

	public function stableId(kind:String, qualifiedName:String):Int
		return idFor(kind + ":" + qualifiedName);

	public function exportState():Bytes {
		var names = [for (name in ids.keys()) name];
		names.sort(Reflect.compare);
		var output = new BytesOutput();
		output.bigEndian = false;
		output.writeString(MAGIC);
		output.writeByte(VERSION);
		output.writeInt32(names.length);
		for (name in names) {
			if (!ids.exists(name))
				throw 'Missing stable type ID for "$name"';
			var value = Bytes.ofString(name);
			output.writeInt32(ids.get(name));
			output.writeInt32(value.length);
			output.write(value);
		}
		return output.getBytes();
	}

	function importState(state:Bytes):Void {
		var input = new BytesInput(state);
		input.bigEndian = false;
		try {
			if (input.readString(3) != MAGIC || input.readByte() != VERSION)
				throw "Invalid type identity state";
			var count = input.readInt32();
			if (count < 0 || count > 0x100000)
				throw "Invalid type identity count";
			for (_ in 0...count) {
				var id = input.readInt32(), length = input.readInt32();
				if (id <= 0 || length < 0 || length > 0x100000)
					throw "Invalid type identity entry";
				var name = input.readString(length);
				if (ids.exists(name))
					throw "Duplicate type identity name";
				ids.set(name, id);
				if (id >= nextId)
					nextId = id + 1;
			}
			if (input.position != state.length)
				throw "Trailing type identity data";
		} catch (error:haxe.io.Eof) {
			throw "Truncated type identity state";
		}
	}

	function idFor(name:String):Int {
		if (ids.exists(name))
			return ids.get(name);
		var result = nextId++;
		ids.set(name, result);
		return result;
	}

	static function classify(previous:Null<TypeDescriptor>, current:TypeDescriptor):TypeCompatibility {
		if (previous == null)
			return NewType;
		if (previous.base != current.base)
			return BaseChanged;
		if (previous.isValue != current.isValue)
			return LayoutChanged;
		if (previous.fields.length != current.fields.length)
			return LayoutChanged;
		for (i in 0...current.fields.length) {
			var oldField = previous.fields[i], newField = current.fields[i];
			if (oldField.name != newField.name || oldField.type != newField.type)
				return LayoutChanged;
		}
		if (previous.methods.length != current.methods.length)
			return MethodSignatureChanged;
		for (i in 0...current.methods.length) {
			var oldMethod = previous.methods[i],
				newMethod = current.methods[i];
			if (oldMethod.name != newMethod.name || oldMethod.signature != newMethod.signature)
				return MethodSignatureChanged;
		}
		return Compatible;
	}
}
