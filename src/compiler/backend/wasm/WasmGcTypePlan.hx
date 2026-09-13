package compiler.backend.wasm;

import compiler.ir.Ir.IrEnum;
import compiler.ir.Ir.IrEnumCase;
import compiler.ir.Ir.IrObject;
import compiler.ir.Ir.IrObjectField;
import compiler.ir.Ir.IrProgram;
import compiler.ir.Ir.IrType;
import compiler.ir.IrOperands;
import compiler.ir.IrFunction;
import compiler.backend.wasm.WasmModule.WasmModule;
import compiler.backend.wasm.WasmTypes.WasmCompositeType;
import compiler.backend.wasm.WasmTypes.WasmFieldType;
import compiler.backend.wasm.WasmTypes.WasmFunctionType;
import compiler.backend.wasm.WasmTypes.WasmHeapType;
import compiler.backend.wasm.WasmTypes.WasmRefType;
import compiler.backend.wasm.WasmTypes.WasmStorageType;
import compiler.backend.wasm.WasmTypes.WasmSubtype;
import compiler.backend.wasm.WasmTypes.WasmTypeGroup;
import compiler.backend.wasm.WasmTypes.WasmValueType;

typedef WasmGcArrayTypePlan = {
	final wrapperTypeIndex:Int;
	final storageTypeIndex:Int;
}

/**
	Plans nominal GC types for an IR program independently from Linear32 byte offsets.
	The planned types are emitted as one recursive group so mutually referring Haxe types
	can use stable indices before function lowering begins.
**/
class WasmGcTypePlan {
	public final program:IrProgram;
	public final typeGroups:Array<WasmTypeGroup>;
	public final objectTypeIndices:Map<String, Int> = [];
	public final objectFieldIndices:Map<String, Map<String, Int>> = [];
	public final enumTypeIndices:Map<String, Int> = [];
	public final enumConstructorTypeIndices:Map<String, Array<Int>> = [];
	public final arrayTypes:Map<String, WasmGcArrayTypePlan> = [];
	public final iteratorTypeIndices:Map<String, Int> = [];
	public final functionTypeIndices:Map<String, Int> = [];
	public final boxedPrimitiveTypeIndices:Map<String, Int> = [];
	public var byteArrayTypeIndex(default, null):Int = -1;
	public var bytesTypeIndex(default, null):Int = -1;
	public var managedBytesTypeIndex(default, null):Int = -1;
	public var closureTypeIndex(default, null):Int = -1;

	final objectDeclarations:Map<String, IrObject> = [];
	final enumDeclarations:Map<String, IrEnum> = [];
	final orderedObjects:Array<IrObject> = [];
	final flattenedObjectFields:Map<String, Array<IrObjectField>> = [];
	final arrayElements:Array<IrType> = [];
	final iteratorElements:Array<IrType> = [];
	final collectedValueTypes:Array<IrType> = [];
	final functionSignatures:Array<WasmGcFunctionSignature> = [];
	final seenArrayElements:Map<String, Bool> = [];
	final seenIteratorElements:Map<String, Bool> = [];
	final seenValueTypes:Map<String, Bool> = [];
	final seenFunctionSignatures:Map<String, Bool> = [];
	final subtypes:Array<WasmSubtype> = [];
	final plannedFunctionTypes:Map<String, WasmFunctionType> = [];

	public function new(program:IrProgram) {
		this.program = program;
		indexDeclarations();
		collectProgramTypes();
		reserveNamedTypes();
		reserveRuntimeTypes();
		reserveGenericTypes();
		validateCollectedValueTypes();
		reserveFunctionTypes();
		defineNamedTypes();
		defineRuntimeTypes();
		defineGenericTypes();
		defineFunctionTypes();
		typeGroups = [RecGroup(subtypes.copy())];
	}

	/** Appends the plan to a fresh module before function signatures are interned. */
	public function addTo(module:WasmModule):Void {
		if (module.typeCount() != 0)
			throw "Wasm GC type plans must be added before other module types";
		for (group in typeGroups)
			switch group {
				case RecGroup(types):
					if (module.addRecGroup(types) != 0)
						throw "Wasm GC type plan did not begin at type index zero";
				case Single(type):
					module.addType(type);
			}
	}

	public function objectType(name:String):Int
		return requireIndex(objectTypeIndices, name, 'Unknown Wasm GC object type "$name"');

	public function objectFieldIndex(objectName:String, fieldName:String):Int {
		var fields = objectFieldIndices.get(objectName);
		if (fields == null || !fields.exists(fieldName))
			throw 'Unknown field "$objectName.$fieldName" in Wasm GC type plan';
		return fields.get(fieldName);
	}

	/** Returns class type indices that can satisfy a Haxe virtual interface cast. */
	public function interfaceImplementors(interfaceName:String):Array<Int> {
		var result:Array<Int> = [];
		for (object in orderedObjects)
			if (objectImplementsInterface(object.name, interfaceName))
				result.push(objectType(object.name));
		return result;
	}

	public function enumType(name:String):Int
		return requireIndex(enumTypeIndices, name, 'Unknown Wasm GC enum type "$name"');

	public function enumConstructorType(name:String, constructor:Int):Int {
		var constructors = enumConstructorTypeIndices.get(name);
		if (constructors == null || constructor < 0 || constructor >= constructors.length)
			throw 'Unknown constructor $constructor in Wasm GC enum "$name"';
		return constructors[constructor];
	}

	/** Enum constructor structs repeat the base tag at field zero; payload fields start at one. */
	public function enumFieldIndex(name:String, constructor:Int, field:Int):Int {
		var declaration = enumDeclarations.get(name);
		if (declaration == null || constructor < 0 || constructor >= declaration.cases.length)
			throw 'Unknown constructor $constructor in Wasm GC enum "$name"';
		if (field < 0 || field >= declaration.cases[constructor].params.length)
			throw 'Unknown field $field in Wasm GC enum constructor $constructor of "$name"';
		return field + 1;
	}

	public function arrayType(element:IrType):Int
		return arrayPlan(element).wrapperTypeIndex;

	public function arrayStorageType(element:IrType):Int
		return arrayPlan(element).storageTypeIndex;

	public static inline function arrayLengthFieldIndex():Int
		return 0;

	public static inline function arrayDataFieldIndex():Int
		return 1;

	public function iteratorType(element:IrType):Int
		return requireIndex(iteratorTypeIndices, typeKey(element), 'Unknown Wasm GC iterator type');

	public static inline function iteratorArrayFieldIndex():Int
		return 0;

	public static inline function iteratorPositionFieldIndex():Int
		return 1;

	public function functionTypeIndex(arguments:Array<IrType>, result:IrType):Int {
		var type = wasmFunctionType(arguments, result),
			key = wasmFunctionTypeKey(type);
		return requireIndex(functionTypeIndices, key, "Wasm GC function signature was not reserved by the type plan");
	}

	public function wasmFunctionType(arguments:Array<IrType>, result:IrType):WasmFunctionType {
		return {
			parameters: [for (argument in arguments) valueType(argument)],
			results: switch result {
				case Void: [];
				default: [valueType(result)];
			}
		};
	}

	public function valueType(type:IrType):WasmValueType {
		return switch type {
			case Void:
				throw "Void has no Wasm GC value type";
			case I32, Bool: I32;
			case I64: I64;
			case F64: F64;
			case TypeRef: I32;
			case Obj(name): Ref(nullableType(objectType(name)));
			case Enum(name): Ref(nullableType(enumType(name)));
			case Array(element): Ref(nullableType(arrayType(element)));
			case Iterator(element): Ref(nullableType(iteratorType(element)));
			case Function(_, _): Ref(nullableType(closureTypeIndex));
			case Bytes: Ref(nullableType(bytesTypeIndex));
			case ManagedBytes: Ref(nullableType(managedBytesTypeIndex));
			// Abstracts and virtual interfaces retain Haxe's existing dispatch metadata and begin as opaque anyrefs.
			case Dyn, Abstract(_), Virtual(_): Ref({nullable: true, heap: Any});
		};
	}

	public function boxedPrimitiveType(type:IrType):Int {
		var key = switch type {
			case I32: "i32";
			case Bool: "bool";
			case I64: "i64";
			case F64: "f64";
			case TypeRef: "type-ref";
			default: throw 'No Wasm GC primitive box exists for $type';
		};
		return requireIndex(boxedPrimitiveTypeIndices, key, 'Missing Wasm GC box type "$key"');
	}

	public static function typeKey(type:IrType):String {
		return switch type {
			case Void: "v";
			case I32: "i";
			case I64: "l";
			case Bool: "b";
			case F64: "d";
			case Bytes: "B";
			case ManagedBytes: "M";
			case Dyn: "D";
			case TypeRef: "T";
			case Array(element): "A" + segment(typeKey(element));
			case Enum(name): "E" + segment(name);
			case Obj(name): "O" + segment(name);
			case Abstract(name): "H" + segment(name);
			case Virtual(name): "V" + segment(name);
			case Iterator(element): "R" + segment(typeKey(element));
			case Function(arguments, result):
				"F"
				+ arguments.length
				+ ":"
				+ [for (argument in arguments) segment(typeKey(argument))].join("") + segment(typeKey(result));
		};
	}

	function indexDeclarations():Void {
		for (object in program.objects) {
			if (objectDeclarations.exists(object.name))
				throw 'Duplicate Wasm GC object declaration "${object.name}"';
			objectDeclarations.set(object.name, object);
		}
		for (enumDecl in program.enums) {
			if (enumDeclarations.exists(enumDecl.name))
				throw 'Duplicate Wasm GC enum declaration "${enumDecl.name}"';
			var caseNames:Map<String, Bool> = [];
			for (constructor in enumDecl.cases) {
				if (caseNames.exists(constructor.name))
					throw 'Duplicate constructor "${constructor.name}" in Wasm GC enum "${enumDecl.name}"';
				caseNames.set(constructor.name, true);
			}
			enumDeclarations.set(enumDecl.name, enumDecl);
		}
		var states:Map<String, Int> = [];
		for (object in program.objects)
			visitObject(object, states);
	}

	function objectImplementsInterface(objectName:String, interfaceName:String):Bool {
		var object = objectDeclarations.get(objectName);
		if (object == null)
			return false;
		for (implemented in object.interfaces)
			if (interfaceExtends(implemented, interfaceName))
				return true;
		return object.base != null && objectImplementsInterface(object.base, interfaceName);
	}

	function interfaceExtends(actual:String, expected:String):Bool {
		if (actual == expected)
			return true;
		for (interfaceDecl in program.interfaces)
			if (interfaceDecl.name == actual)
				for (base in interfaceDecl.bases)
					if (interfaceExtends(base, expected))
						return true;
		return false;
	}

	function visitObject(object:IrObject, states:Map<String, Int>):Void {
		var state = states.get(object.name);
		if (state == 2)
			return;
		if (state == 1)
			throw 'Cyclic Wasm GC object inheritance at "${object.name}"';
		states.set(object.name, 1);
		if (object.base != null) {
			var base = objectDeclarations.get(object.base);
			if (base == null)
				throw 'Unknown Wasm GC base object "${object.base}" for "${object.name}"';
			visitObject(base, states);
		}
		states.set(object.name, 2);
		orderedObjects.push(object);
	}

	function collectProgramTypes():Void {
		for (object in program.objects)
			for (field in object.fields)
				collectType(field.type);
		for (enumDecl in program.enums)
			for (constructor in enumDecl.cases)
				for (parameter in constructor.params)
					collectType(parameter);
		for (interfaceDecl in program.interfaces)
			for (method in interfaceDecl.methods) {
				addFunctionSignature(method.arguments, method.result);
				for (argument in method.arguments)
					collectType(argument);
				collectType(method.result);
			}
		for (field in program.staticFields)
			collectType(field.type);
		for (native in program.natives) {
			addFunctionSignature(native.arguments, native.result);
			for (argument in native.arguments)
				collectType(argument);
			collectType(native.result);
		}
		for (native in program.cNatives) {
			addFunctionSignature(native.arguments, native.result);
			for (argument in native.arguments)
				collectType(argument);
			collectType(native.result);
		}
		for (fn in program.functions)
			collectFunction(fn);
	}

	function collectFunction(fn:IrFunction):Void {
		var arguments = [for (argument in fn.arguments) argument.type];
		addFunctionSignature(arguments, fn.result);
		for (argument in fn.arguments)
			collectType(argument.type);
		collectType(fn.result);
		for (binding in fn.debugBindings)
			collectType(binding.value.type);
		for (block in fn.blocks) {
			for (located in block.instructions) {
				var instruction = located.value,
					output = IrOperands.output(instruction);
				if (output != null)
					collectType(output.type);
				for (input in IrOperands.inputs(instruction))
					collectType(input.type);
				switch instruction {
					case TypeValue(_, type):
						collectType(type);
					default:
				}
			}
			var terminator = block.terminator;
			if (terminator != null)
				switch terminator.value {
					case Return(value), Throw(value), Rethrow(value):
						collectType(value.type);
					case Branch(condition, _, _):
						collectType(condition.type);
					case Jump(_):
				}
		}
	}

	function collectType(type:IrType):Void {
		if (type != Void) {
			var key = typeKey(type);
			if (!seenValueTypes.exists(key)) {
				seenValueTypes.set(key, true);
				collectedValueTypes.push(type);
			}
		}
		switch type {
			case Array(element):
				recordArrayElement(element);
				collectType(element);
			case Iterator(element):
				recordIteratorElement(element);
				recordArrayElement(element);
				collectType(element);
			case Function(arguments, result):
				addFunctionSignature(arguments, result);
				for (argument in arguments)
					collectType(argument);
				collectType(result);
			default:
		}
	}

	function validateCollectedValueTypes():Void {
		for (type in collectedValueTypes)
			valueType(type);
	}

	function recordArrayElement(element:IrType):Void {
		var key = typeKey(element);
		if (!seenArrayElements.exists(key)) {
			seenArrayElements.set(key, true);
			arrayElements.push(element);
		}
	}

	function recordIteratorElement(element:IrType):Void {
		var key = typeKey(element);
		if (!seenIteratorElements.exists(key)) {
			seenIteratorElements.set(key, true);
			iteratorElements.push(element);
		}
	}

	function addFunctionSignature(arguments:Array<IrType>, result:IrType):Void {
		var key = irFunctionSignatureKey(arguments, result);
		if (!seenFunctionSignatures.exists(key)) {
			seenFunctionSignatures.set(key, true);
			functionSignatures.push({arguments: arguments.copy(), result: result});
		}
	}

	function reserveNamedTypes():Void {
		for (object in orderedObjects)
			objectTypeIndices.set(object.name, reserveType());
		for (enumDecl in program.enums) {
			enumTypeIndices.set(enumDecl.name, reserveType());
			var constructorTypes:Array<Int> = [];
			for (_ in enumDecl.cases)
				constructorTypes.push(reserveType());
			enumConstructorTypeIndices.set(enumDecl.name, constructorTypes);
		}
		for (object in orderedObjects) {
			var inherited:Array<IrObjectField> = object.base == null ? [] : flattenedObjectFields.get(object.base).copy();
			inherited = inherited.concat(object.fields);
			flattenedObjectFields.set(object.name, inherited);
			var fieldIndices:Map<String, Int> = [];
			for (index in 0...inherited.length)
				if (!fieldIndices.exists(inherited[index].name))
					fieldIndices.set(inherited[index].name, index);
			objectFieldIndices.set(object.name, fieldIndices);
		}
	}

	function reserveRuntimeTypes():Void {
		byteArrayTypeIndex = reserveType();
		bytesTypeIndex = reserveType();
		managedBytesTypeIndex = reserveType();
		closureTypeIndex = reserveType();
		boxedPrimitiveTypeIndices.set("i32", reserveType());
		boxedPrimitiveTypeIndices.set("bool", reserveType());
		boxedPrimitiveTypeIndices.set("i64", reserveType());
		boxedPrimitiveTypeIndices.set("f64", reserveType());
		boxedPrimitiveTypeIndices.set("type-ref", reserveType());
	}

	function reserveGenericTypes():Void {
		for (element in arrayElements) {
			var key = typeKey(element);
			arrayTypes.set(key, {storageTypeIndex: reserveType(), wrapperTypeIndex: reserveType()});
		}
		for (element in iteratorElements)
			iteratorTypeIndices.set(typeKey(element), reserveType());
	}

	function reserveFunctionTypes():Void {
		for (signature in functionSignatures) {
			var type = wasmFunctionType(signature.arguments, signature.result),
				key = wasmFunctionTypeKey(type);
			if (!functionTypeIndices.exists(key)) {
				functionTypeIndices.set(key, reserveType());
				plannedFunctionTypes.set(key, type);
			}
		}
	}

	function defineNamedTypes():Void {
		for (object in orderedObjects) {
			var fields = flattenedObjectFields.get(object.name),
				baseIndex = object.base == null ? null : objectTypeIndices.get(object.base),
				supertypes:Array<Int> = baseIndex == null ? [] : [baseIndex],
				wasmFields:Array<WasmFieldType> = [
					for (field in fields)
						{
							type: Value(valueType(field.type)),
							mutable: true
						}
				];
			setType(objectType(object.name), false, supertypes, Struct(wasmFields));
		}
		for (enumDecl in program.enums) {
			var base = enumType(enumDecl.name),
				baseFields:Array<WasmFieldType> = [{type: Value(I32), mutable: false}];
			setType(base, false, [], Struct(baseFields));
			var constructorTypes = enumConstructorTypeIndices.get(enumDecl.name);
			for (index in 0...enumDecl.cases.length) {
				var fields = baseFields.copy();
				for (parameter in enumDecl.cases[index].params)
					fields.push({type: Value(valueType(parameter)), mutable: false});
				setType(constructorTypes[index], true, [base], Struct(fields));
			}
		}
	}

	function defineRuntimeTypes():Void {
		setType(byteArrayTypeIndex, true, [], Array({type: I8, mutable: true}));
		setType(bytesTypeIndex, true, [], Struct([
			{type: Value(Ref({nullable: false, heap: Type(byteArrayTypeIndex)})), mutable: true},
			{type: Value(I32), mutable: true},
			{type: Value(I32), mutable: true}
		]));
		setType(managedBytesTypeIndex, true, [], Struct([
			{type: Value(Ref({nullable: false, heap: Type(byteArrayTypeIndex)})), mutable: true},
			{type: Value(I32), mutable: true},
			{type: Value(I32), mutable: true}
		]));
		setType(closureTypeIndex, true, [], Struct([
			{type: Value(I32), mutable: true},
			{type: Value(Ref({nullable: true, heap: Any})), mutable: true}
		]));
		for (entry in [
			{key: "i32", type: I32},
			{key: "bool", type: I32},
			{key: "i64", type: I64},
			{key: "f64", type: F64},
			{key: "type-ref", type: I32}
		])
			setType(boxedPrimitiveTypeIndices.get(entry.key), true, [], Struct([{type: Value(entry.type), mutable: false}]));
	}

	function defineGenericTypes():Void {
		for (element in arrayElements) {
			var plan = arrayPlan(element), wasmElement = valueType(element);
			setType(plan.storageTypeIndex, true, [], Array({type: Value(wasmElement), mutable: true}));
			setType(plan.wrapperTypeIndex, true, [], Struct([
				{type: Value(I32), mutable: true},
				{type: Value(Ref({nullable: false, heap: Type(plan.storageTypeIndex)})), mutable: true}
			]));
		}
		for (element in iteratorElements) {
			var arrayIndex = arrayType(element),
				iteratorIndex = iteratorType(element);
			// Haxe arrays are nullable references, so iterators preserve that in their source field.
			setType(iteratorIndex, true, [], Struct([
				{type: Value(Ref({nullable: true, heap: Type(arrayIndex)})), mutable: true},
				{type: Value(I32), mutable: true}
			]));
		}
	}

	function defineFunctionTypes():Void {
		for (key in plannedFunctionTypes.keys())
			setType(functionTypeIndices.get(key), true, [], Func(plannedFunctionTypes.get(key)));
	}

	function arrayPlan(element:IrType):WasmGcArrayTypePlan {
		var key = typeKey(element), plan = arrayTypes.get(key);
		if (plan == null)
			throw 'Array element type $element was not present when the Wasm GC type plan was built';
		return plan;
	}

	function reserveType():Int {
		var index = subtypes.length;
		subtypes.push({finalType: true, supertypes: [], composite: Struct([])});
		return index;
	}

	function setType(index:Int, finalType:Bool, supertypes:Array<Int>, composite:WasmCompositeType):Void {
		subtypes[index] = {finalType: finalType, supertypes: supertypes, composite: composite};
	}

	static function nullableType(index:Int):WasmRefType
		return {nullable: true, heap: Type(index)};

	static function requireIndex(values:Map<String, Int>, key:String, message:String):Int {
		if (!values.exists(key))
			throw message;
		return values.get(key);
	}

	static function segment(value:String):String
		return value.length + ":" + value;

	static function irFunctionSignatureKey(arguments:Array<IrType>, result:IrType):String
		return arguments.length + ":" + [for (argument in arguments) segment(typeKey(argument))].join("") + segment(typeKey(result));

	static function wasmFunctionTypeKey(type:WasmFunctionType):String
		return type.parameters.length
			+ ":"
			+ [for (parameter in type.parameters) segment(wasmValueTypeKey(parameter))].join("")
				+ ">"
				+ type.results.length
				+ ":"
				+ [for (result in type.results) segment(wasmValueTypeKey(result))].join("");

	static function wasmValueTypeKey(type:WasmValueType):String {
		return switch type {
			case I32: "i";
			case I64: "l";
			case F32: "f";
			case F64: "d";
			case Ref(ref): (ref.nullable ? "?" : "!") + wasmHeapTypeKey(ref.heap);
		};
	}

	static function wasmHeapTypeKey(type:WasmHeapType):String {
		return switch type {
			case Any: "a";
			case Eq: "e";
			case I31: "j";
			case Struct: "s";
			case Array: "r";
			case Func: "f";
			case Extern: "x";
			case None: "n";
			case NoExtern: "o";
			case NoFunc: "q";
			case Exn: "z";
			case NoExn: "w";
			case Type(index): "t" + index;
		};
	}
}

private typedef WasmGcFunctionSignature = {
	final arguments:Array<IrType>;
	final result:IrType;
}
