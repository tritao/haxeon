package compiler.ir;

import compiler.ir.Ir;
import compiler.ir.IrValueLaneLayout.IrValueLaneShape;
import compiler.ir.IrValueLaneLayout.IrValueLaneTarget;

/** Overlapping payload lanes for one enum case. The tag is stored separately. */
typedef IrInlineEnumCaseShape = {
	final name:String;
	final parameters:Array<IrType>;
	final payload:IrValueLaneShape;
}

/** A one-based case tag, scalar words, and managed reference slots. Tag zero denotes null. */
typedef IrInlineEnumShape = {
	final name:String;
	final wordBits:Int;
	final scalarWords:Int;
	final references:Int;
	final cases:Array<IrInlineEnumCaseShape>;
	final valueObject:IrObject;
}

/** Plans inline enum payloads using the same packing rules as struct arrays. */
class IrInlineEnumLayout {
	public static inline final CANONICAL_ABI = "portable-abi64";
	final declarations:Map<String, IrEnum>;
	final objects:Map<String, IrObject>;
	final pointerBits:Int;
	final target:IrValueLaneTarget;
	final canonical:Bool;
	final classificationObjects:Null<Array<IrObject>>;
	final results:Map<String, IrInlineEnumShape> = [];
	final rejected:Map<String, Bool> = [];
	final valueCopies:Map<String, String> = [];
	var decisionPlanner:Null<IrInlineEnumLayout>;

	/** classificationObjects retains the canonical Flat layouts independently of the selected target ABI. */
	public function new(enums:Array<IrEnum>, objects:Array<IrObject>, pointerBits:Int, target:IrValueLaneTarget,
			?classificationObjects:Array<IrObject>, canonical:Bool = false) {
		if (classificationObjects != null) {
			var values = [for (object in classificationObjects) if (object.isValue) object.name => true];
			for (object in objects) if (object.isValue && !values.exists(object.name))
				throw 'Missing canonical value object "${object.name}" for inline enum classification';
		}
		declarations = [for (declaration in enums) declaration.name => declaration];
		this.objects = [for (object in objects) object.name => object];
		this.pointerBits = pointerBits;
		this.target = target;
		this.canonical = canonical;
		this.classificationObjects = classificationObjects;
	}

	/** Recursive and disproportionately large enum payloads remain boxed. */
	public function shape(name:String):Null<IrInlineEnumShape> {
		if (rejected.exists(name)) return null;
		var existing = results.get(name);
		if (existing != null) return existing;
		var declaration = declarations.get(name);
		if (declaration == null || recursive(name, name, [], [])) return reject(name);
		if (!canonical) {
			if (decisionPlanner == null)
				decisionPlanner = new IrInlineEnumLayout([for (entry in declarations) entry],
					classificationObjects == null ? [for (object in objects) object] : classificationObjects, 64, HashLink, null, true);
			if (decisionPlanner.shape(name) == null) return reject(name);
		}
		var cases:Array<{name:String, object:IrObject}> = [];
		for (index in 0...declaration.cases.length) {
			var constructor = declaration.cases[index], caseName = '$' + 'inline-enum-case:$name:$index';
			var fields:Array<IrObjectField> = [];
			for (parameter in 0...constructor.params.length)
				fields.push({name: Std.string(parameter), type: payloadType(constructor.params[parameter])});
			var object:IrObject = {name: caseName, isValue: true, base: null, interfaces: [], fields: fields, methods: []};
			objects.set(caseName, object);
			cases.push({name: constructor.name, object: object});
		}
		var table = IrObjectTable.of(objects), lanes = new IrValueLaneLayout(table, pointerBits, target), wordBits = canonical ? 64 : 32;
		for (entry in cases) if (lanes.shape(Obj(entry.object.name)).scalarWordBits == 64) wordBits = 64;
		var mapped:Array<IrInlineEnumCaseShape> = [], scalarWords = 0, references = 0, largest = 0, second = 0;
		for (entry in cases) {
			var payload = lanes.shape(Obj(entry.object.name), wordBits);
			mapped.push({name: entry.name, parameters: [for (field in entry.object.fields) field.type], payload: payload});
			if (payload.scalarWords > scalarWords) scalarWords = payload.scalarWords;
			if (payload.references > references) references = payload.references;
			var size = payload.scalarWords + payload.references;
			if (size > largest) { second = largest; largest = size; } else if (size > second) second = size;
		}
		if (canonical && largest > 8 && largest > 2 * (second < 1 ? 1 : second)) return reject(name);
		var fields:Array<IrObjectField> = [{name: "tag", type: I32}];
		for (index in 0...scalarWords) fields.push({name: 'scalar$index', type: wordBits == 64 ? I64 : I32});
		for (index in 0...references) fields.push({name: 'reference$index', type: IrValueLaneReference.type()});
		var valueObject:IrObject = {name: '$' + 'inline-enum:$name', isValue: true, base: null, interfaces: [], fields: fields, methods: []};
		objects.set(valueObject.name, valueObject);
		var result:IrInlineEnumShape = {name: name, wordBits: wordBits, scalarWords: scalarWords, references: references,
			cases: mapped, valueObject: valueObject};
		results.set(name, result);
		return result;
	}

	function reject(name:String):Null<IrInlineEnumShape> { rejected.set(name, true); return null; }

	/** Enum value declarations created while planning the requested shapes, in deterministic order. */
	public function generatedObjects():Array<IrObject> {
		var names = [for (name in objects.keys())
			if (StringTools.startsWith(name, "$inline-enum:")) name];
		names.sort(Reflect.compare);
		return [for (name in names) objects.get(name)];
	}

	/** The mapped form of a source value used in a planned enum payload. */
	public function mappedObject(name:String):Null<IrObject> return objects.get(name);

	/** Nested inline enum values contribute their complete tag and payload as value fields. */
	public function payloadType(type:IrType):IrType return switch type {
		case Enum(name): var nested = shape(name); nested == null ? type : Obj(nested.valueObject.name);
		case Nullable(Enum(name)): var nested = shape(name); nested == null ? type : Obj(nested.valueObject.name);
		// Containers and closures are reference leaves. Preserve their semantic element
		// and call types; a private payload record must not become their public ABI.
		case Array(_), Iterator(_), Function(_, _): type;
		case Obj(name):
			var object = objects.get(name);
			if (object == null || !object.isValue) type; else Obj(payloadValueObject(object));
		case Nullable(Obj(name)):
			var object = objects.get(name);
			if (object == null || !object.isValue) type; else Nullable(Obj(payloadValueObject(object)));
		case Nullable(inner): Nullable(payloadType(inner));
		default: type;
	};

	function payloadValueObject(object:IrObject):String {
		// Reusing a Wasm C layout here would count nine pointers as five 64-bit words.
		// The frontend supplies the independently calculated canonical C layouts; never
		// try to reconstruct them from target-specific offsets or erase their padding.
		if (canonical && object.nativeLayout != null && object.nativeLayout.target != CANONICAL_ABI)
			throw 'Inline enum classification requires the canonical $CANONICAL_ABI layout for "${object.name}"';
		var existing = valueCopies.get(object.name);
		if (existing != null) return existing;
		var name = object.name;
		valueCopies.set(object.name, name);
		var fields:Array<IrObjectField> = [for (field in object.fields) {
			name: field.name, type: payloadType(field.type), nativeLayout: field.nativeLayout,
			scalarStorage: field.scalarStorage, nullableScalarStorage: field.nullableScalarStorage
		}];
		objects.set(name, {name: name, isValue: true, nativeLayout: object.nativeLayout, base: object.base,
			interfaces: object.interfaces, fields: fields, methods: object.methods});
		return name;
	}

	function recursive(root:String, current:String, seenEnums:Array<String>, seenObjects:Array<String>):Bool {
		if (seenEnums.indexOf(current) >= 0) return current == root;
		var declaration = declarations.get(current);
		if (declaration == null) return false;
		var next = seenEnums.concat([current]);
		for (constructor in declaration.cases) for (parameter in constructor.params)
			if (contains(root, parameter, next, seenObjects)) return true;
		return false;
	}

	function contains(root:String, type:IrType, seenEnums:Array<String>, seenObjects:Array<String>):Bool return switch type {
		case Enum(name): name == root || (seenEnums.indexOf(name) < 0 && recursive(root, name, seenEnums, seenObjects));
		case Nullable(inner), Array(inner), Iterator(inner): contains(root, inner, seenEnums, seenObjects);
		case Function(arguments, result):
			var found = contains(root, result, seenEnums, seenObjects);
			for (argument in arguments) if (contains(root, argument, seenEnums, seenObjects)) found = true;
			found;
		case Obj(name):
			var object = objects.get(name), found = false;
			if (object != null && object.isValue && seenObjects.indexOf(name) < 0)
				for (field in object.fields) if (contains(root, field.type, seenEnums, seenObjects.concat([name]))) found = true;
			found;
		default: false;
	};
}
