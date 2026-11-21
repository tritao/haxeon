package compiler.ir;

import compiler.core.InternalError;
import compiler.core.Provides;
import compiler.core.Provides.ProviderOperation;
import compiler.core.Provides.ProviderOperations;
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

/**
 * Verified SSA function with explicit arguments, blocks, and result type.
 *
 * A function the inliner stage made is its frozen body (`ofBody`, docs/design/IR_CORE_COLUMNS.md): the backends read the body,
 * and the blocks and debug bindings are decoded from it the first time something reads them, once. A function is never changed
 * once made, so a body a reader encodes for it (`bodyIn`) stays its own.
 *
 * Between the stages that read bodies, in a compile that keeps no session, no cache holds a function's body, so it is not
 * frozen (`ofOwnedBody`, `bodyIn` not `retained`): the stage after the one that made it owns it and edits it in place, and a
 * function made from the edited body replaces this one, which is not read again.
 */
@:allow(compiler.ir.IrBody)
class IrFunction {
	public final name:String;
	public final arguments:Array<IrValue>;
	public final result:IrType;
	public var blocks(get, never):Array<IrBlock>;
	public var debugBindings(get, never):Array<IrDebugBinding>;

	/** The body this function is, when one was made: the one it was made from (`ofBody`), or one `bodyIn` encoded. */
	public var body(default, null):Null<IrBody> = null;

	/** The blocks and bindings, null until decoded from `body`. */
	var decodedBlocks:Null<Array<IrBlock>>;

	var decodedBindings:Null<Array<IrDebugBinding>>;

	@:processWide("a placeholder for blocks not decoded yet, replaced at once and never read or added to")
	static final NOT_DECODED:Array<IrBlock> = [];

	@:processWide("a placeholder for bindings not decoded yet, replaced at once and never read or added to")
	static final NO_BINDINGS:Array<IrDebugBinding> = [];

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
		this.decodedBlocks = blocks;
		this.decodedBindings = debugBindings == null ? [] : debugBindings;
		this.inlineHint = inlineHint;
		this.retention = retention;
		this.kind = kind;
	}

	/** The function `body` is, which must be frozen: its arguments decoded now, its blocks and bindings when first read. */
	public static function ofBody(body:IrBody):IrFunction {
		if (!body.frozen)
			throw new InternalError('IR body ${body.name} is not frozen, so it is not a function yet');
		return ofOwnedBody(body);
	}

	/** The function `body` is, which the stage after the one that made it owns and may edit in place (no cache holds it). */
	public static function ofOwnedBody(body:IrBody):IrFunction {
		var fn = new IrFunction(body.name, body.decodeArguments(), body.types.type(body.result), NOT_DECODED, body.kind,
			NO_BINDINGS, body.inlineHint, body.retention);
		fn.decodedBlocks = null;
		fn.decodedBindings = null;
		fn.body = body;
		return fn;
	}

	/**
	 * This function's body: the one it is, or else its encoding with `types`, kept, so it is made once: frozen when `retained`,
	 * else owned by the stages over bodies, which edit it in place.
	 */
	public function bodyIn(types:IrTypeIds, ?builder:IrBodyBuilder, retained = true):IrBody {
		var known = body;
		// A body is read with its own table (`IrBody.types`), whichever `types` is asked for; splicing rows and comparing bodies
		// across tables is checked where it happens (the inliner's sources, `IrFunctionStateEquality.sameBodies`).
		if (known != null)
			return known;
		var encoded = IrBodyBuilder.encode(this, types, builder),
			made = retained ? encoded.freeze(true) : encoded;
		body = made;
		return made;
	}

	/** Records `encoded`, a frozen body made from this function, as its body, unless it has one. */
	public function keepBody(encoded:IrBody):Void {
		if (!encoded.frozen)
			throw new InternalError('IR body ${encoded.name} is not frozen');
		if (body == null)
			body = encoded;
	}

	/**
	 * Lets the decoded blocks and bindings go when the function has a body to decode them from again: for a function whose
	 * objects nothing will read before the compile ends, so only its body stays live.
	 */
	public function releaseDecoded():Void {
		if (body == null)
			throw new InternalError('IR function $name has no body to decode its blocks from again');
		decodedBlocks = null;
		decodedBindings = null;
	}

	inline function get_blocks():Array<IrBlock> {
		var known = decodedBlocks;
		return known != null ? known : decode().blocks;
	}

	inline function get_debugBindings():Array<IrDebugBinding> {
		var known = decodedBindings;
		return known != null ? known : decode().bindings;
	}

	function decode():{blocks:Array<IrBlock>, bindings:Array<IrDebugBinding>} {
		var source = body;
		if (source == null)
			throw new InternalError('IR function $name has neither blocks nor a body');
		var decoded = source.decodeRest(arguments);
		decodedBlocks = decoded.blocks;
		decodedBindings = decoded.bindings;
		return decoded;
	}

	/**
	 * The first id above every value the function names: its arguments, its instructions' outputs and operands, and its debug
	 * bindings. A pass
	 * that adds values numbers them from here; a binding's value may be gone from the code, and its id must not name another value.
	 */
	public function nextValueId():Int {
		var next = 0;
		for (argument in arguments)
			if (argument.id >= next)
				next = argument.id + 1;
		for (block in blocks)
			for (located in block.instructions) {
				var output = IrOperands.output(located.value);
				if (output != null && output.id >= next)
					next = output.id + 1;
				for (index in 0...IrOperands.count(located.value)) {
					var input = IrOperands.at(located.value, index);
					if (input.id >= next)
						next = input.id + 1;
				}
			}
		for (binding in debugBindings)
			if (binding.value.id >= next)
				next = binding.value.id + 1;
		return next;
	}

	/** The operation this function serves for a type, as a row of the provider table, or `None` when it is not a provider. */
	public var provides(get, never):Provides<TypeKey>;

	function get_provides():Provides<TypeKey>
		return switch kind {
			case Provider(subject, operation): Serves(subject, operation);
			case ValueArraySlot(_, element, _): Serves(TypeKey.of(element),
				ProviderOperations.detailed(ProviderOperation.ValueArraySlot, name));
			// Two source enums can lower to one IR type, each with its own helper, so the helper's name (a function of the source type) is the detail.
			case EnumEquality(reflective): arguments.length == 2 ? Serves(TypeKey.of(arguments[0].type),
				ProviderOperations.detailed(reflective ? ProviderOperation.ReflectEquals : ProviderOperation.Equals,
				name)) : None;
			case EnumDynamicUnbox(type): Serves(TypeKey.of(type), ProviderOperation.DynamicUnbox);
			case EnumTagAdapter(type, box): Serves(TypeKey.of(type),
				box ? ProviderOperation.EnumTagBox : ProviderOperation.EnumTagUnbox);
			default: None;
		};

	/**
	 * This function with other blocks, keeping everything else it declares, its kind included. `arguments`, `result` and
	 * `name` replace the function's own when given; `kind` replaces its kind, which a copy under another name must do when the original
	 * is a provider (two functions never serve one operation for one subject).
	 */
	public function withBlocks(blocks:Array<IrBlock>, ?bindings:Array<IrDebugBinding>, ?arguments:Array<IrValue>,
			?result:IrType, ?name:String,
			?kind:IrFunctionKind):IrFunction {
		return new IrFunction(name == null ? this.name : name, arguments == null ? this.arguments : arguments,
			result == null ? this.result : result, blocks,
			kind == null ? this.kind : kind, bindings == null ? debugBindings : bindings, inlineHint, retention);
	}
}
