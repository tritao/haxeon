package compiler;

/** What a generated function does for a type, as its generator states it when it creates the function. */
enum abstract ProviderOperation(String) to String {
	var Equals = "equals";
	var ReflectEquals = "reflect-equals";
	var Hash = "hash";
	var CustomMethod = "custom-method";
	var Wire = "wire";
	var Json = "json";
	var MapKeyCompare = "map-key-compare";
	var BoxDynamic = "box-dynamic";
	var ViewDynamic = "view-dynamic";
	var DynamicTest = "dynamic-test";
	var DynamicUnbox = "dynamic-unbox";
	var EnumTagBox = "enum-tag-box";
	var EnumTagUnbox = "enum-tag-unbox";
	var DynamicDispatch = "dynamic-dispatch";
	var KeyPath = "keypath";
	var TypedInterfaceEntry = "typed-interface-entry";
	var InlineEnumHelper = "inline-enum-helper";
	var InterfaceBox = "interface-box";
	var InterfaceUnbox = "interface-unbox";
	var InterfaceCast = "interface-cast";
	var InterfaceTypeTest = "interface-type-test";
	var OptionalCopy = "optional-copy";
	var OptionalBox = "optional-box";
	var OptionalUnbox = "optional-unbox";
	var OptionalFieldHelper = "optional-field-helper";
	var NullableScalarHelper = "nullable-scalar-helper";
	var CheckedCast = "checked-cast";
	var ValueArrayElement = "value-array-element";
	var ValueArraySlot = "value-array-slot";
	var ValueArrayMethod = "value-array-method";
	var ValueArrayAccess = "value-array-access";
	var GenericErased = "generic-erased";
	var GenericTypeTest = "generic-type-test";
	var GenericMethodReference = "generic-method-reference";
	var DynamicStructure = "dynamic-structure";
	var StaticInitializer = "static-initializer";
	var ReceiverCheck = "receiver-check";
	var RawRepresentable = "raw-representable";
	var Flags = "flags";
}

/** Operations on the names of provider operations (kept out of the enum abstract: the compiler's own front end reads these sources). */
class ProviderOperations {
	/**
	 * Whether the helpers of this operation are generated on demand from a request in one module and called from others, so a module
	 * that is no longer reachable still holds helpers that reachable code calls (`FrontendCompilation.generatedHelpersStillCalled`).
	 */
	public static function sharedAcrossModules(operation:String):Bool {
		var colon = operation.indexOf(":"), base = colon < 0 ? operation : operation.substr(0, colon);
		return base == ProviderOperation.Equals || base == ProviderOperation.ReflectEquals || base == ProviderOperation.CustomMethod || base == ProviderOperation.Hash || base == ProviderOperation.Wire || base == ProviderOperation.Json || base == ProviderOperation.RawRepresentable || base == ProviderOperation.Flags;
	}

	/** An operation with a further word that tells apart the helpers of one family for a type: `custom-method:hash`, `wire:value-encode`. */
	public static inline function detailed(base:String, detail:String):ProviderOperation
		return cast(base + ":" + detail);
}

/**
 * Whether a function is a helper that serves an operation on a type, and which: the view of `IrFunction.kind` that the provider table
 * (`IrProviders`) reads. `K` is how the type is named; on a function it is `compiler.ir.TypeKey`.
 */
enum Provides<K> {
	/** Not a helper for a type: a user function, a lambda, a clone of another function, an adapter, a marker. */
	None;

	Serves(type:K, operation:ProviderOperation);
}
