package compiler.ir;

import compiler.Provides;
import compiler.Provides.ProviderOperation;
import compiler.ir.Ir;

/** Source binding identity, lexical range, and SSA value after mutable stores vanish. */
typedef IrDebugBinding = {
	final identity:String;
	final name:String;
	final value:IrValue;
	final path:String;
	final scopeStart:Int;
	final scopeEnd:Int;
}

/** Whether a backend that drops uncalled functions must keep one, and whether it exports it to its host. */
enum abstract IrRetention(Int) from Int to Int {
	/** Kept only while something reaches it. */
	var Reachable = 0;

	/** Declared `@:keep`: kept even when nothing calls it. */
	var Keep = 1;

	/** Declared `@:expose`: kept and exported under its name so the host can call it. */
	var Expose = 2;
}

/** A generated value-array place operation and its logical operands. */
enum IrValueArraySlotOperation {
	Read(slot:Int, path:Array<String>, carrier:Bool);
	Write(slot:Int, path:Array<String>, carrier:Bool);
	Check(path:Array<String>, includeSelf:Bool);
	OptionalWrite(path:Array<String>, type:IrType);
	RequireScalar(type:IrType);
}

/**
 * What a function is, declared by the generator that made it. A function that serves an operation on a type is a `Provider` (the
 * provider table, `IrProviders`, is an index over these); the others are copies or boundary functions of another function, and a
 * function with no declaration is `Ordinary`. Every `$`-named function in the final IR must be something other than `Ordinary`
 * (`IrProviders.check`), so a pass never recognizes a generated function by the shape of its name.
 */
enum IrFunctionKind {
	/** A user function, or one whose name needs no declaration. */
	Ordinary;

	GenericSpecialization;
	SourceLambda;
	IterationAdapter;

	/** Serves `operation` for `subject`; two functions never serve the same operation for the same subject (`IrProviders.check`). */
	Provider(subject:TypeKey, operation:ProviderOperation);

	/** A generated value-array place operation: its element type, namespace and the operation with its logical operands. */
	ValueArraySlot(namespace:Int, element:IrType, operation:IrValueArraySlotOperation);

	/**
	 * The equality helpers of an enum, with the structured enum roles of the tag-storage passes: they carry the enum IR type they work on,
	 * and the provider table sees them as `Equals` / `ReflectEquals`, `DynamicUnbox`, and `EnumTagBox` / `EnumTagUnbox` of that enum.
	 */
	EnumEquality(reflective:Bool);

	EnumDynamicUnbox(type:IrType);
	EnumTagAdapter(type:IrType, box:Bool);

	/** A generated function that serves no type: runtime, ABI or backend plumbing (lane storage, word helpers, the entry's wrappers). */
	GeneratedHelper;

	/** A copy of a function for the scalar call ABI, an optional-scalar copy (of the named function), or a nullable-scalar one. */
	ScalarArguments;
	OptionalScalar(original:Null<String>);
	NullableScalarArguments;
	WasmClosureRestore;

	/** Compiler-declared semantic signatures of closure boundary functions. */
	ClosureAdapter(source:IrType, target:IrType);
	ClosureCast(target:IrType);
	ClosureVarargs(target:IrType);
}

/** Verified SSA function with explicit arguments, blocks, and result type. */
class IrFunction {
	public final name:String;
	public final arguments:Array<IrValue>;
	public final result:IrType;
	public final blocks:Array<IrBlock>;
	public final debugBindings:Array<IrDebugBinding>;

	/** Declared `inline` in source; the inliner allows a larger body for such a function. */
	public final inlineHint:Bool;

	public final retention:IrRetention;

	/** What this function is; required, so a function made without saying what it is does not compile. */
	public final kind:IrFunctionKind;

	public function new(name, arguments, result, blocks, kind:IrFunctionKind, ?debugBindings, inlineHint = false,
			retention:IrRetention = Reachable) {
		this.name = name;
		this.arguments = arguments;
		this.result = result;
		this.blocks = blocks;
		this.debugBindings = debugBindings == null ? [] : debugBindings;
		this.inlineHint = inlineHint;
		this.retention = retention;
		this.kind = kind;
	}

	/** The operation this function serves for a type, as a row of the provider table, or `None` when it is not a provider. */
	public var provides(get, never):Provides<TypeKey>;

	function get_provides():Provides<TypeKey>
		return switch kind {
			case Provider(subject, operation): Serves(subject, operation);
			case ValueArraySlot(_, element, _): Serves(TypeKey.of(element), ProviderOperation.detailed(ProviderOperation.ValueArraySlot, name));
			case EnumEquality(reflective): arguments.length == 2 ? Serves(TypeKey.of(arguments[0].type), reflective ? ProviderOperation.ReflectEquals : ProviderOperation.Equals) : None;
			case EnumDynamicUnbox(type): Serves(TypeKey.of(type), ProviderOperation.DynamicUnbox);
			case EnumTagAdapter(type, box): Serves(TypeKey.of(type), box ? ProviderOperation.EnumTagBox : ProviderOperation.EnumTagUnbox);
			default: None;
		};

	/**
	 * This function with other blocks, keeping everything else it declares, its kind included. `arguments`, `result` and
	 * `name` replace the function's own when given; `kind` replaces its kind, which a copy under another name must do when the original
	 * is a provider (two functions never serve one operation for one subject).
	 */
	public function withBlocks(blocks:Array<IrBlock>, ?bindings:Array<IrDebugBinding>, ?arguments:Array<IrValue>, ?result:IrType, ?name:String,
			?kind:IrFunctionKind):IrFunction
		return new IrFunction(name == null ? this.name : name, arguments == null ? this.arguments : arguments, result == null ? this.result : result,
			blocks, kind == null ? this.kind : kind, bindings == null ? debugBindings : bindings, inlineHint, retention);
}
