import compiler.Frontend;
import compiler.ir.Ir;
import compiler.ir.IrFunction.IrFunctionKind;
import compiler.ir.IrScalarAbiEligibility;
import sys.io.File;

/** Scalar ABI selection is a declared role, not a property of a linkage name. */
class ScalarAbiEligibilityMain {
	static function check(kind:IrFunctionKind, shared:Bool, wasm:Bool):Void {
		if (IrScalarAbiEligibility.permits(kind, false) != shared || IrScalarAbiEligibility.permits(kind, true) != wasm)
			throw 'Wrong scalar ABI eligibility for $kind';
	}

	static function main():Void {
		for (kind in [Ordinary, GenericSpecialization, SourceLambda, Equality, Hash, KeyPath, IterationAdapter,
			InlineEnumAccess, TypedInterface, ValueUnbox, GenericMethodReference, OptionalScalar(null),
			OptionalScalar("original"), OptionalValueBoundary, ValueArrayElement]) check(kind, true, true);
		for (kind in [NullableScalarArguments, WasmClosureRestore]) check(kind, false, true);
		for (kind in [GeneratedHelper, ScalarArguments]) check(kind, false, false);
		var source:IrType = Function([I32], I32), target:IrType = Function([Dyn], Dyn);
		for (kind in [ClosureAdapter(source, target), ClosureCast(target), ClosureVarargs(target)]) check(kind, true, true);
		var program = Frontend.compile(File.getContent("tests/programs/generic-struct-functions.hx")), user = false, generic = false;
		for (fn in program.functions) switch fn.kind {
			case Ordinary: user = true;
			case GenericSpecialization: generic = true;
			default:
		}
		if (!user || !generic) throw "Source and specialized functions must retain their declared roles";
		Sys.println("PASS: scalar ABI eligibility follows declared function roles");
	}
}
