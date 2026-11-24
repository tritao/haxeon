package compiler.ir.model;

import compiler.ir.model.SourceProvenance.Located;

/** Backend-oriented value types carried by the SSA intermediate representation. */
enum IrType {
	Void;
	I32;
	I64;
	Bool;
	F32;
	F64;
	Bytes;

	/** Unmanaged address carried in one target pointer register. */
	RawPtr;

	/** GC-managed byte storage used by haxe.io.Bytes and projected HXI structs. */
	ManagedBytes;

	Dyn;

	/**
	 * A boxed primitive that may be null (`Null<Int>`, `Null<Float>`, `Null<Bool>`, `Null<Int64>`). It has the
	 * representation of `Dyn` and converts to and from it freely, but records which primitive it holds: HashLink gives it
	 * a `HNull` register type, so the JIT can read the value without a runtime cast. `IrTypeTools.erase` turns it back
	 * into `Dyn` for the backends that have no use for the distinction.
	 */
	Nullable(element:IrType);

	TypeRef;
	Array(element:IrType);
	Enum(name:String);

	/** Payload-free enum storage: constructor index + 1 in I32; zero is the null value. */
	EnumTag(name:String);

	Obj(name:String);
	Abstract(name:String);
	Virtual(name:String);
	Iterator(element:IrType);
	Function(arguments:Array<IrType>, result:IrType);
}

/** Immutable SSA definition with a function-local numeric identity. */
@:nullSafety(Strict)
class IrValue {
	public final id:Int;
	public final name:String;
	public final type:IrType;

	public function new(id, name, type) {
		this.id = id;
		this.name = name;
		this.type = type;
	}
}

/** Value contributed by one predecessor to an SSA phi definition. */
typedef IrPhiInput = {
	final block:Int;
	final value:IrValue;
}

/** Compiler operations whose operands include semantic data rather than encoded linkage names. */
enum IrIntrinsic {
	/** Answered by ProviderOperation.BoxDynamic. */
	EnumDynamicBox(type:IrType);

	/** Answered by ProviderOperation.ViewDynamic. */
	EnumDynamicView(type:IrType);

	/** Answered by ProviderOperation.EnumTagBox. */
	EnumTagBox(type:IrType);

	/** Answered by ProviderOperation.EnumTagUnbox. */
	EnumTagUnbox(type:IrType);

	/** Answered by ProviderOperation.InlineEnumHelper(box); type is the logical enum and the operand uses its inline storage. */
	InlineEnumBox(type:IrType);

	/** Answered by ProviderOperation.InlineEnumHelper(unbox); type is the logical enum and the result uses its inline storage. */
	InlineEnumUnbox(type:IrType);
}

/** Typed SSA operations independent of HashLink register and symbol indices. */
enum IrInstruction {
	Phi(output:IrValue, inputs:Array<IrPhiInput>);
	ConstVoid(output:IrValue);
	ConstInt(output:IrValue, value:Int);
	ConstFloat(output:IrValue, value:Float);
	ConstString(output:IrValue, value:String);
	StaticDataAddress(output:IrValue, bytes:Array<Int>);
	PointerOffset(output:IrValue, pointer:IrValue, byteOffset:IrValue);
	MemoryLoad(output:IrValue, pointer:IrValue, size:Int, signed:Bool);
	MemoryStore(pointer:IrValue, value:IrValue, size:Int);
	ConstBool(output:IrValue, value:Bool);
	ConstNull(output:IrValue);
	TypeValue(output:IrValue, type:IrType);
	ToDyn(output:IrValue, value:IrValue);
	IntToFloat(output:IrValue, value:IrValue);
	IntToInt64(output:IrValue, value:IrValue);
	FloatToInt(output:IrValue, value:IrValue);
	FloatToFloat(output:IrValue, value:IrValue);
	SafeCast(output:IrValue, value:IrValue);

	/** A cleanup guard preserves the pending exception stack across the protected code. */
	BeginTry(catchBlock:Int, afterBlock:Int, preserveExceptionStack:Bool);

	EndTry(catchBlock:Int, preserveExceptionStack:Bool);
	Catch(output:IrValue);
	GlobalGet(output:IrValue, name:String);
	GlobalSet(name:String, value:IrValue);
	Add(output:IrValue, left:IrValue, right:IrValue);
	Sub(output:IrValue, left:IrValue, right:IrValue);
	Mul(output:IrValue, left:IrValue, right:IrValue);
	Div(output:IrValue, left:IrValue, right:IrValue);
	Mod(output:IrValue, left:IrValue, right:IrValue);
	BitAnd(output:IrValue, left:IrValue, right:IrValue);
	BitXor(output:IrValue, left:IrValue, right:IrValue);
	BitOr(output:IrValue, left:IrValue, right:IrValue);
	ShiftLeft(output:IrValue, left:IrValue, right:IrValue);
	ShiftRight(output:IrValue, left:IrValue, right:IrValue);
	UnsignedShiftRight(output:IrValue, left:IrValue, right:IrValue);
	Less(output:IrValue, left:IrValue, right:IrValue);
	LessEqual(output:IrValue, left:IrValue, right:IrValue);
	Equal(output:IrValue, left:IrValue, right:IrValue);
	Call(output:IrValue, target:IrSymbol, arguments:Array<IrValue>);
	CNativeCall(output:IrValue, functionName:String, arguments:Array<IrValue>);
	StaticClosure(output:IrValue, target:IrSymbol);
	InstanceClosure(output:IrValue, target:IrSymbol, receiver:IrValue);
	CallClosure(output:IrValue, closure:IrValue, arguments:Array<IrValue>);
	ToVirtual(output:IrValue, value:IrValue);

	/** The same object as an instance of one of its base classes: a reinterpretation, never checked or copied. */
	Upcast(output:IrValue, value:IrValue);

	/**
	 * The dense class id of the object's class (`IrProgram.classIds`): an I32 that indexes the dispatch tables of interface calls. The object's class
	 * must be one that has an id (a constructed class); each backend reads it as it likes (a class method, the struct's runtime type, a field).
	 */
	ClassId(output:IrValue, object:IrValue);

	/** Terminal receiver means this compiler-owned value place is dead after this call, including on its exception edge. */
	MethodCall(output:IrValue, object:IrValue, methodName:String, arguments:Array<IrValue>, terminalReceiver:Bool);

	NewObject(output:IrValue, typeName:String);

	/** The default value of output.type; it has no observable identity or effects. */
	ValueInit(output:IrValue);

	FieldGet(output:IrValue, object:IrValue, fieldName:String);
	FieldSet(object:IrValue, fieldName:String, value:IrValue);
	ArrayGet(output:IrValue, array:IrValue, index:IrValue);
	ArraySet(array:IrValue, index:IrValue, value:IrValue);
	ArraySize(output:IrValue, array:IrValue);
	IteratorNew(output:IrValue, array:IrValue);
	IteratorHasNext(output:IrValue, iterator:IrValue);
	IteratorNext(output:IrValue, iterator:IrValue);
	MakeEnum(output:IrValue, typeName:String, constructor:Int, arguments:Array<IrValue>);
	EnumIndex(output:IrValue, value:IrValue);
	EnumField(output:IrValue, value:IrValue, constructor:Int, field:Int);
	Intrinsic(output:IrValue, operation:IrIntrinsic, arguments:Array<IrValue>);
}

/** Mandatory control transfer ending an SSA basic block. */
enum IrTerminator {
	/**
	 * Control cannot reach here by construction (a method of a class nothing constructs, an unreceivable call): no value, no successors. It is
	 * not an exception: Haxe code cannot catch it. Wasm lowers it to `unreachable`; HashLink to the fatal runtime native `__unreachable`.
	 */
	Unreachable;

	Return(value:IrValue);
	Throw(value:IrValue);
	Rethrow(value:IrValue);
	Jump(target:Int);
	Branch(condition:IrValue, whenTrue:Int, whenFalse:Int);

	/**
	 * A dense multiway branch on an `I32`: `targets[value]` when `0 <= value < targets.length`, `otherwise` for any other value.
	 * An enum switch is one on the constructor index; HashLink lowers it to a jump table (`OSwitch`).
	 */
	Switch(value:IrValue, targets:Array<Int>, otherwise:Int);
}

/** SSA basic block identified independently of its position in the block array. */
@:nullSafety(Strict)
class IrBlock {
	public final id:Int;
	public final instructions:Array<Located<IrInstruction>>;
	public var terminator:Null<Located<IrTerminator>>;

	/** A block with no instructions yet, or one that takes `instructions` as its own (not copied). */
	public function new(id, ?instructions:Array<Located<IrInstruction>>) {
		this.id = id;
		this.instructions = instructions == null ? [] : instructions;
	}
}

/** Runtime-native function required by an IR program. */
typedef IrNative = {
	final name:String;
	final library:String;
	final symbol:String;
	final arguments:Array<IrType>;
	final result:IrType;

	/** Functions referenced by backend-generated lowering for this native call. */
	@:optional final generatedFunctionDependencies:Null<Array<String>>;
}

/** Ordinary C ABI symbol required by an IR program. */
enum IrCNativeArgumentMode {
	Value;
	BytesInput(lengthArgument:Int);
	BytesInputOutput(lengthArgument:Int);
	BytesOutput(lengthArgument:Int);
	BytesSize;
	Output;
	InputOutput;
	FixedInput(size:Int, alignment:Int, pointerFree:Bool);
	FixedValue(size:Int, alignment:Int, pointerFree:Bool);
	FixedOutput(size:Int, alignment:Int, pointerFree:Bool);
	FixedInputOutput(size:Int, alignment:Int, pointerFree:Bool);
}

typedef IrCNativeFixedLayout = {
	final size:Int;
	final alignment:Int;
	final pointerFree:Bool;
}

typedef IrCNative = {
	final name:String;
	final library:String;
	final symbol:String;
	final signature:String;
	final pointerOwnership:String;
	final pointerRelease:Null<String>;
	final pointerLength:Null<String>;
	final pointerNullable:Bool;
	@:optional final pointerSize:Null<Int>;
	@:optional final fixedResult:Null<IrCNativeFixedLayout>;
	final arguments:Array<IrType>;
	final argumentModes:Array<IrCNativeArgumentMode>;
	final result:IrType;
}

/** C-compatible placement metadata for one field in an inferred Flat record. */
typedef IrObjectFieldNativeLayout = {
	final offset:Int;
	final size:Int;
	final alignment:Int;
	final signed:Bool;
	final inlineRecord:Bool;
}

/** C-compatible payload layout for a Flat record on the active ABI. */
typedef IrObjectNativeLayout = {
	final target:String;
	final size:Int;
	final alignment:Int;
}

/** Width and signedness of a stored scalar, independent of an enclosing record's native layout. */
typedef IrScalarStorage = {
	final size:Int;
	final signed:Bool;
}

/** Runtime-visible field in an IR object layout. */
typedef IrObjectField = {
	final name:String;
	final type:IrType;
	@:optional final nativeLayout:Null<IrObjectFieldNativeLayout>;
	@:optional final scalarStorage:Null<IrScalarStorage>;

	/** Width of a boxed nullable primitive's payload, independent of the nullable reference's storage. */
	@:optional final nullableScalarStorage:Null<IrScalarStorage>;
}

/** Method name and implementing function attached to an IR object; the function by symbol, as a call names it. */
typedef IrObjectMethod = {
	final name:String;
	final functionName:IrSymbol;
}

/** Object layout and dispatch metadata required by backend lowering. */
typedef IrObject = {
	final name:String;
	final isValue:Bool;
	@:optional final nativeLayout:Null<IrObjectNativeLayout>;
	final base:Null<String>;
	final interfaces:Array<String>;
	final fields:Array<IrObjectField>;
	final methods:Array<IrObjectMethod>;
}

/** Copies of an IR object that change one part and carry every other field over, including ones added later. */
@:nullSafety(Strict)
class IrObjectTools {
	public static function withMethods(object:IrObject, methods:Array<IrObjectMethod>):IrObject {
		var copy:Dynamic = Reflect.copy(object);
		copy.methods = methods;
		return copy;
	}

	/**
	 * Whether two objects declare the same name, kind, base, interfaces, fields (names and types) and methods (names and the
	 * functions they name): what the whole-program walks read of an object (`IrWalkRecord`).
	 */
	public static function sameShape(left:IrObject, right:IrObject):Bool {
		if (left == right)
			return true;
		if (left.name != right.name || left.isValue != right.isValue || left.base != right.base
			|| !sameNames(left.interfaces, right.interfaces) || left.fields.length != right.fields.length
			|| left.methods.length != right.methods.length)
			return false;
		for (index in 0...left.fields.length) {
			var a = left.fields[index], b = right.fields[index];
			if (a.name != b.name || !compiler.ir.model.IrTypeIdentity.same(a.type, b.type))
				return false;
		}
		for (index in 0...left.methods.length) {
			var a = left.methods[index], b = right.methods[index];
			if (a.name != b.name || a.functionName.name != b.functionName.name)
				return false;
		}
		return true;
	}

	/** Whether two lists of names are equal. */
	public static function sameNames(left:Array<String>, right:Array<String>):Bool {
		if (left.length != right.length)
			return false;
		for (index in 0...left.length)
			if (left[index] != right[index])
				return false;
		return true;
	}
}

/** Callable contract required by an IR interface. */
typedef IrInterfaceMethod = {
	final name:String;
	final arguments:Array<IrType>;
	final result:IrType;
}

/** Interface inheritance and method contracts required by backend lowering. */
typedef IrInterface = {
	final name:String;
	final bases:Array<String>;
	final methods:Array<IrInterfaceMethod>;
}

/** Ordered payload types of one IR enum constructor. */
typedef IrEnumCase = {
	final name:String;
	final params:Array<IrType>;
}

/** Enum layout required by backend lowering. */
typedef IrEnum = {
	final name:String;
	final cases:Array<IrEnumCase>;
	final ?isRecursive:Bool;

	/** Private value record used by typed storage; the public enum descriptor remains nominal. */
	final ?inlineStorage:String;
}

/** Module-level storage slot required by an IR program. */
typedef IrStaticField = {
	final name:String;
	final type:IrType;
}

/**
 * The value a call that leaves out an optional parameter passes for it, when it is a literal (`IrProgram.parameterDefaults`).
 * Callers fill in defaults, so the function itself never sees whether an argument was given.
 */
enum IrDefault {
	NullDefault;
	IntDefault(value:Int);
	FloatDefault(value:Float);
	BoolDefault(value:Bool);
}

/** Complete register-independent program assembled into a HashLink module. */
@:nullSafety(Strict)
class IrProgram {
	public var natives:Array<IrNative> = [];
	public var cNatives:Array<IrCNative> = [];

	/**
	 * After the inliner stage each function is its frozen body (`IrFunction.ofBody`): the HashLink backend reads the bodies, and a
	 * function's blocks are decoded from its body only when something reads them, once.
	 */
	public var functions:Array<IrFunction> = [];
	public var objects:Array<IrObject> = [];
	public var interfaces:Array<IrInterface> = [];
	public var enums:Array<IrEnum> = [];
	public var staticFields:Array<IrStaticField> = [];
	public var entryPoint:String;

	/**
	 * The code fingerprint (`IrFunctionStateCodec.codeFingerprint`) of every positionally named function (`PositionalName`), when
	 * the build records them.
	 */
	public var positionalFingerprints:Map<String, String> = [];

	/**
	 * For a live build: the literal defaults of each function's optional parameters, by function and parameter name. A function
	 * whose signature changes leaves an adapter in its old slot for the closures that hold it (`HlModuleAssembler`), and the
	 * adapter passes these for the parameters the old calls lack.
	 */
	public var parameterDefaults:Map<String, Map<String, IrDefault>> = [];

	/**
	 * Where each positionally named function's code starts in its source (`PositionalName.place`), and the text of each file
	 * named there, by path: an edit's text diff then tells which edited lambda is which (`LambdaAlignment`).
	 */
	public var positionalPlaces:Map<String, String> = [];

	public var positionalSources:Map<String, String> = [];

	/**
	 * The dense class id of every class that has one (`ClassId`), assigned by `IrClassIds`: a class keeps its id for a whole live session, a new class
	 * takes the next one, and the id of a removed class is never reused.
	 */
	public var classIds:Map<String, Int> = [];

	/** The functions the early prune (`IrEntryPrune`) removed, for its check mode: no later pass may call one. Empty without the prune. */
	public var prunedFunctions:Map<String, Bool> = [];

	/**
	 * Lookups the passes share over this program (`IrProgramIndex.of`, `IrMethodResolution.of`), each rebuilt when the declaration
	 * arrays it was made from change. They are the program's own, so they go with it, and a copy starts without them.
	 */
	public var index:Null<compiler.ir.model.IrProgramIndex> = null;

	public var methodResolution:Null<compiler.ir.analysis.IrMethodResolution> = null;

	/** The fields of the final program never null once constructed (`IrNonNullFields.of`). */
	public var nonNullFields:Null<compiler.ir.analysis.IrNonNullFields> = null;

	/** The HaxeonHost C function each runtime native calls on Wasm, by native name (`WasmModuleSupport.hostCNative`). */
	public var hostCNatives:Null<Map<String, IrCNative>> = null;

	/**
	 * Names of the natives that reached code calls, from the walk from the entry (`IrEntryPrune`) of every build but a live HashLink one; null in
	 * that one, where every declared native counts. A decision about what the program does at run time (does it reflect?) reads this, not the declared natives of every loaded module.
	 */
	public var reachedNatives:Null<Map<String, Bool>> = null;

	/** The generated helpers of this program, by what each serves (`IrProviders`); an index over `functions`, built when asked. */
	public function providers():Map<String, String>
		return IrProviders.rows(functions);

	public function new(entryPoint:String)
		this.entryPoint = entryPoint;

	/** A program with its own function and native lists, sharing everything else with this one. */
	public function copy():IrProgram {
		var result = new IrProgram(entryPoint);
		result.natives = natives.copy();
		result.cNatives = cNatives;
		result.functions = functions.copy();
		result.objects = objects;
		result.interfaces = interfaces;
		result.enums = enums;
		result.staticFields = staticFields;
		result.positionalFingerprints = positionalFingerprints;
		result.parameterDefaults = parameterDefaults;
		result.positionalPlaces = positionalPlaces;
		result.positionalSources = positionalSources;
		result.prunedFunctions = prunedFunctions;
		result.reachedNatives = reachedNatives;
		result.classIds = classIds;
		return result;
	}
}
