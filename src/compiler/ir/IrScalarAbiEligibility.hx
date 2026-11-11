package compiler.ir;

import compiler.ir.IrFunction.IrFunctionKind;

/** Which declared function roles may use each target's scalar calling convention. */
class IrScalarAbiEligibility {
	public static function permits(kind:IrFunctionKind, wasm:Bool):Bool
		return switch kind {
			case Ordinary, GenericSpecialization, SourceLambda, Equality, ReflectiveEquality, Hash, KeyPath, IterationAdapter,
				InlineEnumAccess, TypedInterface, ValueUnbox, GenericMethodReference, OptionalScalar(_),
				OptionalValueBoundary, ValueArrayElement, ClosureAdapter(_, _), ClosureCast(_), ClosureVarargs(_): true;
			case NullableScalarArguments, WasmClosureRestore: wasm;
			case GeneratedHelper, ScalarArguments, ValueArraySlot(_, _, _): false;
		};
}
