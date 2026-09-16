package compiler.ffi;

import compiler.ffi.HxiAbi.HxiAbi;
import compiler.ffi.HxiAbi.HxiAbiValue;
import compiler.ffi.HxiModel.HxiDeclaration;
import compiler.ffi.HxiModel.HxiInterface;
import compiler.ffi.HxiModel.HxiResultPolicy;
import compiler.ffi.HxiSemantics.HxiSemanticFunction;
import compiler.ffi.NativeCallPlan.NativeCallPlan;
import compiler.ffi.NativeCallPlan.NativeDispatch;

typedef HxiFunctionAbi = NativeCallPlan;

/** Lowers a normalized HXI function into its complete target-specific native signature. */
class HxiNativeSignature {
	public static function lower(model:HxiInterface, abi:HxiAbi, ?visibleDeclarations:Map<String, HxiDeclaration>):Array<HxiFunctionAbi> {
		var semantics = HxiSemantics.normalize(model, abi, visibleDeclarations),
			declarations:Map<String, HxiDeclaration> = [];
		for (declaration in model.declarations)
			switch declaration {
				case Function(name, _, _, _, _, _, _, _):
					declarations.set(name, declaration);
				case _:
			}
		var result:Array<HxiFunctionAbi> = [];
		for (semantic in semantics.functions) {
			switch declarations.get(semantic.name) {
				case Function(name, parameters, returnType, symbol, leaf, callConvention, resultPolicy, _):
					result.push({
						name: name,
						symbol: symbol == null ? name : symbol,
						library: model.library,
						arguments: [for (parameter in parameters) abi.classify(parameter.type)],
						result: abi.classify(returnType, true),
						leaf: leaf,
						callConvention: callConvention,
						resultPolicy: resultPolicy,
						semantics: semantic,
						dispatch: DirectSymbol
					});
				case _:
			}
		}
		return result;
	}
}
