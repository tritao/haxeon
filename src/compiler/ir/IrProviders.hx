package compiler.ir;

import compiler.Provides;
import compiler.Provides.ProviderOperation;

/** Kinds of derived function (see `IrProviders.families`). */
enum DerivedFamily {
	Lambda;
	FunctionAdapter;
	IterationAdapter;
	Generic;
	KeyPathCompose;
	ScalarArgumentsClone;
	OptionalScalarClone;
	NullableArgumentsClone;
	WasmRestoreCall;
	Other;
}

/**
 * The table of generated helpers: which function serves which operation on which type. A generator states it when it creates the
 * function (`IrFunction.provides`), so the table is an index over the functions, not a second thing to keep in step with them.
 *
 * The passes that need to know what a generated function is (the scalar call ABI of the HashLink and Wasm backends, the optional-scalar
 * flow, the dispatchers, the typing-time liveness of shared helpers) ask this table through the functions below; none of them
 * recognizes a helper by the prefix of its name any more. Do not add a prefix list: give the generator's operation a place here.
 * The names that remain are those of derived functions (`families`), which serve no type.
 */
class IrProviders {
	/** Kinds of `$`-named function that are not helpers for a type: copies of another function, closures, adapters, markers. */
	public static final families:Array<{prefix:String, family:DerivedFamily}> = [
		{prefix: "$lambda:", family: Lambda},
		{prefix: "$lambda-env:", family: Lambda},
		{prefix: "$function-adapter:", family: FunctionAdapter},
		{prefix: "$iteration-adapter:", family: IterationAdapter},
		{prefix: "$enum-interface:", family: Other},
		{prefix: "$keypath.compose:", family: KeyPathCompose},
		{prefix: "$generic:", family: Generic},
		{prefix: "$scalar-arguments:", family: ScalarArgumentsClone},
		{prefix: "$optional-scalar:", family: OptionalScalarClone},
		{prefix: "$nullable-scalar:arguments:", family: NullableArgumentsClone},
		{prefix: "$scalar-closure:", family: Other},
		{prefix: "$wasm:closure-restore-call:", family: WasmRestoreCall},
		{prefix: "$wasm", family: Other},
		{prefix: "$word:", family: Other},
		{prefix: "$lane:", family: Other},
		{prefix: "$lane-runtime:", family: Other},
		{prefix: "$lane-storage:", family: Other},
		{prefix: "$hl:", family: Other},
		{prefix: "$value-dynamic-equal", family: Other},
		{prefix: "$enum-dynamic-equal", family: Other},
		{prefix: "$enum-dynamic-reflect", family: Other},
		{prefix: "$value-interface-object-type-id", family: Other},
		{prefix: "$type-dependency:", family: Other},
		{prefix: "$to-string", family: Other},
		{prefix: "$fresh-constructor:", family: Other},
		{prefix: "$receiver-readonly:", family: Other},
		{prefix: "$haxeon", family: Other}
	];

	/** The kind of derived function `name` is, or null when it is not one. This list is the one place such names are recognized. */
	public static function familyOf(name:String):Null<DerivedFamily> {
		if (!StringTools.startsWith(name, "$"))
			return null;
		for (entry in families)
			if (StringTools.startsWith(name, entry.prefix))
				return entry.family;
		return null;
	}

	public static function isDerivedName(name:String):Bool
		return familyOf(name) != null;

	/** The operation without the detail words after its first colon. */
	public static function base(operation:String):String {
		var colon = operation.indexOf(":");
		return colon < 0 ? operation : operation.substr(0, colon);
	}

	/**
	 * Whether a `$`-named function takes part in the scalar call ABI as an ordinary function does (the others are boundary helpers
	 * whose signatures the ABI must not change). Functions not named `$` always take part: callers test that themselves. `wasm` adds
	 * the kinds only the Wasm backends make.
	 */
	public static function scalarAbiHelper(fn:IrFunction, wasm:Bool = false):Bool
		return switch fn.provides {
			case Serves(_, operation):
				switch base(operation) {
					case ProviderOperation.Equals, ProviderOperation.ReflectEquals, ProviderOperation.Hash, ProviderOperation.InlineEnumHelper,
						ProviderOperation.TypedInterfaceEntry, ProviderOperation.InterfaceUnbox, ProviderOperation.GenericMethodReference,
						ProviderOperation.KeyPath, ProviderOperation.OptionalBox, ProviderOperation.OptionalUnbox, ProviderOperation.ValueArrayElement,
						ProviderOperation.DynamicDispatch: true;
					default: false;
				}
			case None:
				switch familyOf(fn.name) {
					case Lambda, IterationAdapter, Generic, KeyPathCompose, OptionalScalarClone: true;
					case WasmRestoreCall, NullableArgumentsClone: wasm;
					default: false;
				}
		};

	/** Whether a call to `fn` may pass an optional-scalar alias as an argument: `$` functions that do not keep it. */
	public static function passesAliases(fn:IrFunction):Bool
		return switch fn.provides {
			case Serves(type, operation):
				switch base(operation) {
					case ProviderOperation.Equals: !type.isEnum();
					case ProviderOperation.Hash: true;
					default: false;
				}
			case None:
				switch familyOf(fn.name) {
					case Lambda, Generic: true;
					default: false;
				}
		};

	/** Whether `fn` is the equality helper of a value type, or a copy of one made for the scalar call ABI. */
	public static function isValueEquality(fn:IrFunction, byName:Map<String, IrFunction>):Bool {
		var current = fn;
		while (current != null) {
			switch current.provides {
				case Serves(type, operation):
					return base(operation) == ProviderOperation.Equals && !type.isEnum();
				case None:
			}
			if (familyOf(current.name) != ScalarArgumentsClone)
				return false;
			var original = IrScalarArguments.originalName(current.name);
			current = original == null ? null : byName.get(original);
		}
		return false;
	}

	/** (type key, operation) to function name, for every helper in `functions`. */
	public static function rows(functions:Array<IrFunction>):Map<String, String> {
		var result:Map<String, String> = [];
		for (fn in functions)
			switch fn.provides {
				case Serves(type, operation):
					result.set(row(type, operation), fn.name);
				case None:
			}
		return result;
	}

	/** A newline, not a NUL, between the parts: HashLink compares map keys as C strings, so a NUL would end the key. */
	public static function row(type:TypeKey, operation:String):String
		return operation + "\n" + type.toString();

	/**
	 * HAXEON_CHECK_REUSE=1: every function whose name starts with `$` is a provider or a derived function, and no two functions
	 * serve the same operation on the same type. Returns the first problem found, or null.
	 */
	public static function check(functions:Array<IrFunction>):Null<String> {
		var seen:Map<String, String> = [];
		for (fn in functions)
			switch fn.provides {
				case Serves(type, operation):
					var key = row(type, operation), earlier = seen.get(key);
					if (earlier != null && earlier != fn.name)
						return 'functions "$earlier" and "${fn.name}" both serve "$operation" for "$type"';
					seen.set(key, fn.name);
				case None:
					if (StringTools.startsWith(fn.name, "$") && !isDerivedName(fn.name))
						return 'function "${fn.name}" is named like a generated helper but does not say what it serves';
			}
		return null;
	}
}
