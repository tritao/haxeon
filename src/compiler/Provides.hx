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
	var ValueArrayHelper = "value-array-helper";
	var GenericErased = "generic-erased";
	var GenericTypeTest = "generic-type-test";
	var GenericMethodReference = "generic-method-reference";
	var DynamicStructure = "dynamic-structure";
	var LaneRuntime = "lane-runtime";
	var StaticInitializer = "static-initializer";
	var ReceiverCheck = "receiver-check";

	/** An operation with a further word that tells apart the helpers of one family for a type: `custom-method:hash`, `wire:value-encode`. */
	public static inline function detailed(base:String, detail:String):ProviderOperation
		return cast(base + ":" + detail);
}

/**
 * Whether a function is a helper that serves an operation on a type, and which. Every `$`-named function in the final IR is one of
 * these, a clone or lambda or adapter of another function (`None`, checked against `Provides.isDerivedName`), or the check fails:
 * see `IrProviders.check`. The type key is the string the generator hashes into the name (`SemanticSignature.type` of the type, or
 * the IR type's text for a helper made in an IR pass).
 */
enum Provides {
	/** Not a helper for a type: a user function, a lambda, a clone of another function, an adapter, a marker. */
	None;

	Serves(typeKey:String, operation:ProviderOperation);
}
