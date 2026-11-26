package compiler.ir.passes.enums;

import compiler.ir.model.IrObjectTable;
import compiler.ir.passes.values.IrValueLaneLayout;
import compiler.ir.passes.values.IrValueLaneReference;
import compiler.core.InternalError;
import compiler.ir.model.Ir;
import compiler.ir.passes.values.IrValueLaneLayout.IrValueLaneShape;
import compiler.ir.passes.values.IrValueLaneLayout.IrValueLaneTarget;
import compiler.ir.reuse.IrStageMemo.IrStageMemos;

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
@:nullSafety(Strict)
class IrInlineEnumLayout {
	public static inline final CANONICAL_ABI = "portable-abi64";
	public static inline final VALUE_PREFIX = "$inline-enum:";
	final declarations:Map<String, IrEnum>;
	final objects:Map<String, IrObject>;
	final pointerBits:Int;
	final target:IrValueLaneTarget;
	final canonical:Bool;
	final classificationObjects:Null<Array<IrObject>>;
	final eligible:Null<Map<String, Bool>>;
	final results:Map<String, IrInlineEnumShape> = [];
	final rejected:Map<String, Bool> = [];
	final valueCopies:Map<String, String> = [];
	var decisionPlanner:Null<IrInlineEnumLayout>;

	/** The session's stage memos and their kind of the lanes this layout lays out (`lanesOf`); null without a session. */
	final stageMemos:Null<IrStageMemos>;

	final laneMemos:Null<compiler.query.ComputedQueryKind<IrInlineEnumLanes>>;

	/**
	 * classificationObjects retains the canonical Flat layouts independently of the selected target ABI. In a session
	 * (`stageMemos`) an enum's lanes are last build's while the objects they read are the same.
	 */
	public function new(enums:Array<IrEnum>, objects:Array<IrObject>, pointerBits:Int, target:IrValueLaneTarget,
			?classificationObjects:Array<IrObject>, canonical:Bool = false, ?eligible:Map<String, Bool>,
			?stageMemos:IrStageMemos) {
		if (classificationObjects != null) {
			var values = [for (object in classificationObjects) if (object.isValue) object.name => true];
			for (object in objects) if (object.isValue && !values.exists(object.name))
				throw new InternalError('Missing canonical value object "${object.name}" for inline enum classification');
		}
		declarations = [for (declaration in enums) declaration.name => declaration];
		this.objects = [for (object in objects) object.name => object];
		this.pointerBits = pointerBits;
		this.target = target;
		this.canonical = canonical;
		this.classificationObjects = classificationObjects;
		this.eligible = eligible;
		this.stageMemos = stageMemos;
		laneMemos = stageMemos == null ? null : stageMemos.inlineEnumLanes('$pointerBits $target $canonical');
	}

	/**
	 * What the layouts read besides the program's enums and objects, as text: the pointer width, the target, whether the layouts
	 * are canonical, and the classification objects' value layouts.
	 */
	public function inputs():String {
		var parts = ['$pointerBits $target $canonical'];
		var classification = classificationObjects;
		if (classification != null)
			for (object in classification)
				if (object.isValue)
					parts.push(object.name + (object.nativeLayout != null ? " native " : " ")
						+ [for (field in object.fields) field.name + ":"
						+ compiler.ir.model.IrTypeIdentity.text(field.type)].join(","));
		return parts.join("\n");
	}

	/** Recursive and disproportionately large enum payloads remain boxed. */
	public function shape(name:String):Null<IrInlineEnumShape> {
		if (eligible != null && !eligible.exists(name)) return reject(name);
		if (rejected.exists(name)) return null;
		var existing = results.get(name);
		if (existing != null) return existing;
		var declaration = declarations.get(name);
		if (declaration == null || declaration.isRecursive == true
			|| recursive(name, name, [], [])) return reject(name);
		if (!canonical) {
			if (decisionPlanner == null)
				decisionPlanner = new IrInlineEnumLayout([for (entry in declarations) entry],
					classificationObjects == null ? [for (object in objects) object] : classificationObjects, 64,
					HashLink, null, true, null, stageMemos);
			if (decisionPlanner.shape(name) == null) return reject(name);
		}
		var cases:Array<{name:String, object:IrObject}> = [];
		for (index in 0...declaration.cases.length) {
			var constructor = declaration.cases[index], caseName = '$' + 'inline-enum-case:$name:$index';
			var fields:Array<IrObjectField> = [];
			for (parameter in 0...constructor.params.length)
				fields.push({name: Std.string(parameter), type: payloadType(constructor.params[parameter])});
			var object:IrObject = {
				name: caseName,
				isValue: true,
				base: null,
				interfaces: [],
				fields: fields,
				methods: []
			};
			objects.set(caseName, object);
			cases.push({name: constructor.name, object: object});
		}
		var lanes = lanesOf(name, cases), wordBits = lanes.wordBits;
		var mapped:Array<IrInlineEnumCaseShape> = [], scalarWords = 0, references = 0, largest = 0, second = 0;
		for (index in 0...cases.length) {
			var entry = cases[index], payload = lanes.payloads[index];
			mapped.push({
				name: entry.name,
				parameters: [for (field in entry.object.fields) field.type],
				payload: payload
			});
			if (payload.scalarWords > scalarWords) scalarWords = payload.scalarWords;
			if (payload.references > references) references = payload.references;
			var size = payload.scalarWords + payload.references;
			if (size > largest) {
				second = largest;
				largest = size;
			} else if (size > second) second = size;
		}
		if (canonical && largest > 8 && largest > 2 * (second < 1 ? 1 : second)) return reject(name);
		var fields:Array<IrObjectField> = [{name: "tag", type: I32}];
		for (index in 0...scalarWords) fields.push({name: 'scalar$index', type: wordBits == 64 ? I64 : I32});
		for (index in 0...references) fields.push({name: 'reference$index', type: IrValueLaneReference.type()});
		var valueObject:IrObject = {
			name: VALUE_PREFIX + name,
			isValue: true,
			base: null,
			interfaces: [],
			fields: fields,
			methods: []
		};
		objects.set(valueObject.name, valueObject);
		var result:IrInlineEnumShape = {
			name: name,
			wordBits: wordBits,
			scalarWords: scalarWords,
			references: references,
			cases: mapped,
			valueObject: valueObject
		};
		results.set(name, result);
		return result;
	}

	/**
	 * The lanes of the cases of the enum `name`, each case's object in `cases`: in a session last build's while every object they
	 * read is the same shape (`IrInlineEnumLanes.holds`), as they read nothing else but the pointer width and the target; with
	 * `--check-reuse` laid out again and compared.
	 */
	function lanesOf(name:String, cases:Array<{name:String, object:IrObject}>):IrInlineEnumLanes {
		var memos = stageMemos,
			kind = laneMemos,
			key = compiler.ir.model.IrTypeIds.id(Enum(name)),
			kept:Null<IrInlineEnumLanes> = kind == null ? null : kind.kept(key);
		if (memos != null && kind != null && kept != null && kept.holds(objects, cases.length) && !memos.checks)
			return kind.put(memos.database, key, kept);
		var table = IrObjectTable.of(objects), consulted:Map<String, Bool> = [];
		if (kind != null)
			table.consulted = consulted;
		var lanes = new IrValueLaneLayout(table, pointerBits, target), wordBits = canonical ? 64 : 32;
		for (entry in cases) if (lanes.shape(Obj(entry.object.name)).scalarWordBits == 64) wordBits = 64;
		var payloads = [for (entry in cases) lanes.shape(Obj(entry.object.name), wordBits)];
		if (memos == null || kind == null)
			return new IrInlineEnumLanes(wordBits, payloads, [], []);
		var names = [for (read in consulted.keys()) read],
			made = new IrInlineEnumLanes(wordBits, payloads, names, [for (read in names) objects.get(read)]);
		if (kept != null && kept.holds(objects, cases.length)) {
			if (!made.same(kept))
				throw new InternalError('--check-reuse: the inline enum layout reused lanes of "$name" that differ from laying them out now');
			return kind.put(memos.database, key, kept);
		}
		return kind.put(memos.database, key, made);
	}

	function reject(name:String):Null<IrInlineEnumShape> {
		rejected.set(name, true);
		return null;
	}

	/** Enum value declarations created while planning the requested shapes, in deterministic order. */
	public function generatedObjects():Array<IrObject> {
		var generated = [for (name => object in objects)
			if (StringTools.startsWith(name, VALUE_PREFIX)) {
				name: name, object: object
			}];
		generated.sort((a, b) -> Reflect.compare(a.name, b.name));
		return [for (entry in generated) entry.object];
	}

	/** The mapped form of a source value used in a planned enum payload. */
	public function mappedObject(name:String):Null<IrObject> return objects.get(name);

	/** Nested inline enum values contribute their complete tag and payload as value fields. */
	public function payloadType(type:IrType):IrType return switch type {
		case Enum(name): var nested = shape(name);
			nested == null ? type : Obj(nested.valueObject.name);
		case Nullable(Enum(name)): var nested = shape(name);
			nested == null ? type : Obj(nested.valueObject.name);
		// Containers and closures are reference leaves. Preserve their semantic element
		// and call types; a private payload record must not become their public ABI.
		case Array(_), Iterator(_), Function(_, _): type;
		case Obj(name):
			var object = objects.get(name);
			if (object == null || !object.isValue) type;
			else Obj(payloadValueObject(object));
		case Nullable(Obj(name)):
			var object = objects.get(name);
			if (object == null || !object.isValue) type;
			else Nullable(Obj(payloadValueObject(object)));
		case Nullable(inner): Nullable(payloadType(inner));
		default: type;
	};

	function payloadValueObject(object:IrObject):String {
		// Reusing a Wasm C layout here would count nine pointers as five 64-bit words.
		// The frontend supplies the independently calculated canonical C layouts; never
		// try to reconstruct them from target-specific offsets or erase their padding.
		if (canonical && object.nativeLayout != null && object.nativeLayout.target != CANONICAL_ABI)
			throw new InternalError('Inline enum classification requires the canonical $CANONICAL_ABI layout for "${object.name}"');
		var existing = valueCopies.get(object.name);
		if (existing != null) return existing;
		var name = object.name;
		valueCopies.set(object.name, name);
		var fields:Array<IrObjectField> = [for (field in object.fields) {
			name: field.name, type: payloadType(field.type), nativeLayout: field.nativeLayout,
			scalarStorage: field.scalarStorage, nullableScalarStorage: field.nullableScalarStorage
		}];
		objects.set(name, {
			name: name,
			isValue: true,
			nativeLayout: object.nativeLayout,
			base: object.base,
			interfaces: object.interfaces,
			fields: fields,
			methods: object.methods
		});
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

	function contains(root:String, type:IrType, seenEnums:Array<String>,
			seenObjects:Array<String>):Bool return switch type {
				case Enum(name): name == root
					|| (seenEnums.indexOf(name) < 0 && recursive(root, name, seenEnums, seenObjects));
				case Nullable(inner): contains(root, inner, seenEnums, seenObjects);
				case Obj(name):
					var object = objects.get(name), found = false;
					if (object != null && object.isValue && seenObjects.indexOf(name) < 0)
						for (field in object.fields) if (contains(root, field.type, seenEnums,
							seenObjects.concat([name]))) found = true;
					found;
				default: false;
			};
}

/**
 * The lanes `IrInlineEnumLayout.shape` laid out for the cases of one enum: the payload word width, each case's payload, and the
 * objects the layout read by name (null where none was found), which it is a function of besides the pointer width and target.
 */
@:nullSafety(Strict)
class IrInlineEnumLanes {
	public final wordBits:Int;
	public final payloads:Array<IrValueLaneShape>;

	final names:Array<String>;
	final objects:Array<Null<IrObject>>;

	public function new(wordBits:Int, payloads:Array<IrValueLaneShape>, names:Array<String>,
			objects:Array<Null<IrObject>>) {
		this.wordBits = wordBits;
		this.payloads = payloads;
		this.names = names;
		this.objects = objects;
	}

	/** Whether the enum's `cases` objects, laid out against `table`, would read what these were laid out from. */
	public function holds(table:Map<String, IrObject>, cases:Int):Bool {
		if (cases != payloads.length)
			return false;
		for (index in 0...names.length) {
			var now = table.get(names[index]), then = objects[index];
			if (now == null || then == null ? now != then : !IrObjectTools.sameShape(now, then))
				return false;
		}
		return true;
	}

	/** Whether two layouts of an enum's lanes are the same, for `--check-reuse`. */
	public function same(other:IrInlineEnumLanes):Bool {
		if (wordBits != other.wordBits || payloads.length != other.payloads.length)
			return false;
		for (index in 0...payloads.length)
			if (!IrValueLaneLayout.sameShape(payloads[index], other.payloads[index]))
				return false;
		return true;
	}
}
