package compiler.ffi;

import compiler.ffi.HxiAbi.HxiAbi;
import compiler.ffi.HxiAbi.HxiAbiValue;
import compiler.ffi.HxiModel.HxiDeclaration;
import compiler.ffi.HxiModel.HxiInterface;
import compiler.ffi.HxiModel.HxiParameter;
import compiler.ffi.HxiModel.HxiType;
import compiler.ffi.HxiNativeSignature.HxiFunctionAbi;
import compiler.ffi.HaxeProjectionModel;
import compiler.ffi.HaxeProjectionModel.ProjectedOutputStrategy;
import compiler.ffi.HaxeProjectionModel.ProjectedHandleKind;
import compiler.ffi.HxiProjectionProfile;
import compiler.ffi.HxiSemantics.HxiSemanticParameterKind;
import compiler.ffi.HxiSemantics.HxiSemanticResultKind;

/** Decides which Haxe-facing declarations and checked/output wrappers exist. */
class HxiProjectionPlanner {
	public static function plan(path:String, source:HxiInterface, ?omitted:Map<String, Bool>, ?visibleDeclarations:Map<String, HxiDeclaration>,
			?providedAbi:HxiAbi, ?providedProfile:HxiProjectionProfile):HaxeProjectionModel {
		var profile = providedProfile == null ? HxiProjectionProfile.empty() : providedProfile;
		if (providedProfile != null && providedProfile.interfaceName != null)
			HxiProjectionProfileValidator.validate(path, source, omitted, visibleDeclarations, profile);
		var abi = providedAbi == null ? HxiAbi.forInterface(source, visibleDeclarations) : providedAbi,
			declarations = abi.semanticDeclarations(),
			signatures:Map<String, HxiFunctionAbi> = [for (signature in abi.functions()) signature.name => signature],
			enums:Array<ProjectedEnum> = [],
			structures:Array<ProjectedStruct> = [],
			handles:Array<ProjectedHandle> = [],
			callbacks:Array<ProjectedCallback> = [],
			functions:Array<ProjectedFunction> = [];

		for (declaration in source.declarations) {
			var nativeName = declarationName(declaration);
			if (HxiHaxeEmitter.isOmitted(omitted, nativeName))
				continue;
			switch declaration {
				case Enumeration(name, _, flags, values, _):
					var prefix = HxiHaxeEmitter.enumValuePrefix(values, profile);
					enums.push({
						nativeName: name,
						name: HxiHaxeEmitter.enumTypeName(name, profile),
						flags: flags,
						values: [
							for (value in values)
								{
									nativeName: value.name,
									name: HxiHaxeEmitter.enumValueName(value.name, prefix, name, profile),
									value: haxe.Int64.toStr(value.value)
								}
						]
					});
				case Structure(name, size, alignment, fields, _):
					structures.push({
						nativeName: name,
						name: HxiHaxeEmitter.projectedTypeName(name, profile),
						size: size,
						alignment: alignment,
						fields: [
							for (field in fields)
								{
									nativeName: field.name,
									name: HxiHaxeEmitter.projectedFieldName(name, field.name, profile),
									type: field.type,
									offset: field.offset
								}
						]
					});
				case Handle(name, _, destroy, _):
					var owner = destroy == null ? null : ownedHandle(name, destroy, profile);
					handles.push({
						nativeName: name,
						name: HxiHaxeEmitter.projectedTypeName(name, profile),
						kind: ValueHandle,
						ownedName: owner == null ? null : owner.name,
						owned: owner
					});
				case Opaque(name, _):
					handles.push({
						nativeName: name,
						name: HxiHaxeEmitter.projectedTypeName(name, profile),
						kind: OpaqueHandle,
						ownedName: HxiHaxeEmitter.ownedTypeName(name, profile),
						owned: null
					});
				case Callback(name, parameters, result, callConvention, _):
					callbacks.push({
						nativeName: name,
						name: HxiHaxeEmitter.projectedTypeName(name, profile),
						arguments: [for (parameter in parameters) abi.classify(parameter.type)],
						result: abi.classify(result, true),
						callConvention: callConvention
					});
				case Function(name, parameters, result, _, _, _, _, _):
					var signature = signatures.get(name);
					if (signature == null)
						throw 'Missing native signature for HXI function "$name"';
					functions.push(projectFunction(source, name, parameters, result, signature, profile));
				case Alias(_, _, _) | Constant(_, _, _):
			}
		}
		return new HaxeProjectionModel(source, omitted, visibleDeclarations, abi, profile, enums, structures, handles, callbacks, functions);
	}

	static function projectFunction(source:HxiInterface, nativeName:String, parameters:Array<HxiParameter>, result:HxiType, signature:HxiFunctionAbi,
			profile:HxiProjectionProfile):ProjectedFunction {
		var publicName = HxiHaxeEmitter.projectedFunctionName(nativeName, profile),
			derivedCountParameters:Map<String, Bool> = [],
			outputs:Array<ProjectedOutputResult> = [];
		for (parameter in signature.semantics.parameters)
			switch parameter.kind {
				case OutputBuffer(size) | OutputArray(_, size):
					derivedCountParameters.set(size, true);
				case _:
			}
		for (parameter in signature.semantics.parameters)
			switch parameter.kind {
				case OutputHandle(handle, owned, cleanup):
					outputs.push({
						parameter: parameter.name,
						type: owned ? HxiHaxeEmitter.ownedTypeName(handle, profile) : HxiHaxeEmitter.projectedTypeName(handle, profile),
						owned: owned,
						destroy: cleanup,
						semantics: parameter.kind
					});
				case InOutValue(_) if (derivedCountParameters.exists(parameter.name)):
				case OutputValue(value) | InOutValue(value):
					var projected = HxiHaxeEmitter.project(value, false, profile);
					if (projected == null)
						throw 'Unsupported projected output type for "${parameter.name}" in "$nativeName"';
					outputs.push({
						parameter: parameter.name,
						type: projected.haxeType,
						owned: false,
						destroy: null,
						semantics: parameter.kind
					});
				case OutputBuffer(_):
					outputs.push({
						parameter: parameter.name,
						type: "haxe.io.Bytes",
						owned: false,
						destroy: null,
						semantics: parameter.kind
					});
				case OutputArray(_, _):
					outputs.push({
						parameter: parameter.name,
						type: "Array<Null<String>>",
						owned: false,
						destroy: null,
						semantics: parameter.kind
					});
				case InputValue(_) | InputArray(_, _) | InputBytes(_) | RetainedCallback(_):
			}

		var ownedResult:Null<ProjectedOwnedHandle> = switch signature.semantics.result {
			case OwnedHandle(name, destroy): ownedHandle(name, destroy, profile);
			case _: null;
		},
			callbackResult = switch signature.result {
				case CallbackValue(_, _, _, _): true;
				case _: false;
			},
			outputStrategy = outputStrategy(signature),
			resultType = projectedResultType(signature, profile),
			hasOutputParameters = outputStrategy != NoOutputWrapper,
			aggregateResult = switch signature.result {
				case AggregateValue(name, _, _): HxiHaxeEmitter.projectedTypeName(name, profile);
				case _: null;
			},
			rawName = hasOutputParameters
				|| ownedResult != null
				|| aggregateResult != null
				|| callbackResult ? '__hxi_raw_$nativeName' : publicName,
			policy = HxiHaxeEmitter.resultErrorProjection(result, profile),
			checked:Null<ProjectedCheckedFunction> = null,
			byteSlice:Null<String> = null;

		for (parameter in signature.semantics.parameters)
			switch parameter.kind {
				case InputBytes(_):
					byteSlice = publicName + "_slice";
					break;
				case _:
			}

		if (policy != null)
			checked = {
				name: publicName + policy.checkedSuffix,
				returnType: checkedReturnType(outputs),
				outputs: outputs,
				policy: policy
			};

		return {
			nativeName: nativeName,
			name: publicName,
			rawName: rawName,
			nativeSignature: signature,
			resultType: resultType,
			outputs: outputs,
			hasOutputParameters: hasOutputParameters,
			outputStrategy: outputStrategy,
			ownedResult: ownedResult,
			checked: checked,
			byteSliceName: byteSlice
		};
	}

	static function outputStrategy(signature:HxiFunctionAbi):ProjectedOutputStrategy {
		var hasOutput = false, isBuffer = false, isArray = false;
		for (parameter in signature.semantics.parameters)
			switch parameter.kind {
				case InputValue(_) | RetainedCallback(_):
				case InputArray(_, _) | InputBytes(_) | OutputValue(_) | OutputHandle(_, _, _) | InOutValue(_):
					hasOutput = true;
				case OutputBuffer(_):
					hasOutput = true;
					isBuffer = true;
				case OutputArray(_, _):
					hasOutput = true;
					isArray = true;
			}
		return isArray ? OutputArray : isBuffer ? OutputBuffer : hasOutput ? OutputValues : NoOutputWrapper;
	}

	static function projectedResultType(signature:HxiFunctionAbi, profile:HxiProjectionProfile):String {
		return switch signature.semantics.result {
			case OwnedHandle(name, _): HxiHaxeEmitter.ownedTypeName(name, profile);
			case OwnedPointer(value, _):
				switch value {
					case PointerValue(_, nullable, opaquePointee, _) if (opaquePointee != null):
						var name = HxiHaxeEmitter.ownedTypeName(opaquePointee, profile);
						nullable ? 'Null<$name>' : name;
					case _: projectedAbiType(value, profile);
				}
			case ManagedBytes(_, _, _, _): "haxe.io.Bytes";
			case BorrowedPointer(value) | PlainValue(value): projectedAbiType(value, profile);
			case BorrowedHandle(name): HxiHaxeEmitter.projectedTypeName(name, profile);
		};
	}

	static function projectedAbiType(value:HxiAbiValue, profile:HxiProjectionProfile):String {
		var projected = HxiHaxeEmitter.project(value, true, profile);
		return projected == null ? "Void" : projected.haxeType;
	}

	static function checkedReturnType(outputs:Array<ProjectedOutputResult>):String
		return switch outputs.length {
			case 0: "Void";
			case 1: outputs[0].type;
			case _:
				"{" + [for (output in outputs) output.parameter + ":" + output.type].join(", ") + "}";
		};

	static function ownedHandle(nativeName:String, destroy:String, profile:HxiProjectionProfile):ProjectedOwnedHandle
		return {nativeName: nativeName, name: HxiHaxeEmitter.ownedTypeName(nativeName, profile), destroy: destroy};

	static function declarationName(declaration:HxiDeclaration):String
		return HxiHaxeEmitter.declarationName(declaration);
}
