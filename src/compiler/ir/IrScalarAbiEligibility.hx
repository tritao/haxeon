package compiler.ir;

import compiler.Provides.ProviderOperation;
import compiler.ir.IrFunction.IrFunctionKind;

/**
 * Which declared kinds of function may use each target's scalar calling convention: the one predicate. A `$`-named function that is not
 * listed is a boundary helper whose signature the ABI must not change; functions not named `$` always take part and callers test that.
 */
class IrScalarAbiEligibility {
	public static function permits(kind:IrFunctionKind, wasm:Bool):Bool
		return switch kind {
			case Ordinary, GenericSpecialization, SourceLambda, IterationAdapter, OptionalScalar(_), ClosureAdapter(_, _), ClosureCast(_), ClosureVarargs(_): true;
			case Provider(_, operation):
				switch IrProviders.base(operation) {
					case ProviderOperation.Equals, ProviderOperation.ReflectEquals, ProviderOperation.Hash, ProviderOperation.InlineEnumHelper,
						ProviderOperation.TypedInterfaceEntry, ProviderOperation.InterfaceUnbox, ProviderOperation.GenericMethodReference,
						ProviderOperation.KeyPath, ProviderOperation.OptionalBox, ProviderOperation.OptionalUnbox, ProviderOperation.ValueArrayElement,
						ProviderOperation.DynamicDispatch: true;
					default: false;
				}
			case EnumEquality(_): true;
			case NullableScalarArguments, WasmClosureRestore: wasm;
			case GeneratedHelper, ScalarArguments, ValueArraySlot(_, _, _), EnumDynamicUnbox(_), EnumTagAdapter(_, _): false;
		};
}
