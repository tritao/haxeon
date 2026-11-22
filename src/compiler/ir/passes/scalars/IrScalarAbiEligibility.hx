package compiler.ir.passes.scalars;

import compiler.core.Provides.ProviderOperation;
import compiler.ir.model.IrFunction.IrFunctionKind;
import compiler.ir.model.IrProviders;

/**
 * Which declared kinds of function may use each target's scalar calling convention: the one predicate. A `$`-named function that is not
 * listed is a boundary helper whose signature the ABI must not change; functions not named `$` always take part and callers test that.
 */
@:nullSafety(Strict)
class IrScalarAbiEligibility {
	public static function permits(kind:IrFunctionKind, wasm:Bool):Bool
		return switch kind {
			case Ordinary, GenericSpecialization, SourceLambda, IterationAdapter, OptionalScalar(_),
				ClosureAdapter(_, _), ClosureCast(_), ClosureVarargs(_): true;
			case Provider(_, operation):
				switch IrProviders.base(operation) {
					case ProviderOperation.Equals, ProviderOperation.ReflectEquals, ProviderOperation.Hash,
						ProviderOperation.InlineEnumHelper,
						ProviderOperation.TypedInterfaceEntry, ProviderOperation.InterfaceUnbox,
						ProviderOperation.MethodReference,
						ProviderOperation.KeyPath, ProviderOperation.OptionalBox, ProviderOperation.OptionalUnbox,
						ProviderOperation.ValueArrayElement,
						ProviderOperation.DynamicDispatch, ProviderOperation.OptionalCopy: true;
					default: false;
				}
			case EnumEquality(_): true;
			case NullableScalarArguments, WasmClosureRestore: wasm;
			case GeneratedHelper, ScalarArguments, ValueArraySlot(_, _, _), EnumDynamicUnbox(_),
				EnumTagAdapter(_, _): false;
		};
}
