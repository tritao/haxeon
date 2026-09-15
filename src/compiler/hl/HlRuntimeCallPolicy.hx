package compiler.hl;

import compiler.hl.HlCode.HlTypeDef;
import compiler.hl.persistence.HlRuntimeIdentity.HlRuntimeManifest;

/** Pure call-shape policy shared by host and Haxe-built runtime loaders. */
class HlRuntimeCallPolicy {
	public static function validShape(shape:Int):Bool
		return shape >= 0 && shape <= 6;

	/** Whether one manifest identity resolves to the requested runtime ABI shape. */
	public static function validFunction(model:HlModule, identity:HlRuntimeManifest, stableId:Int, shape:Int):Bool {
		var functionIndex = -1;
		for (entry in identity.entries)
			if (entry.stableId == stableId) {
				functionIndex = entry.functionIndex;
				break;
			}
		var fn = model.functionAt(functionIndex);
		if (fn == null)
			return false;

		var argumentCount:Int, resultKind:Null<HlType>;
		switch model.typeAt(fn.type) {
			case Function(arguments, result):
				argumentCount = arguments.length;
				resultKind = typeKind(model, result);
			default:
				return false;
		}

		var expectedArguments = shape == 3 || shape == 6 ? 1 : 0;
		if (argumentCount != expectedArguments)
			return false;
		var expectedResult:Null<HlType> = switch shape {
			case 0, 6: HlType.I32;
			case 1, 3: HlType.Void;
			case 2: HlType.Bytes;
			case 4: HlType.Fun;
			default: null;
		};
		return expectedResult == null || resultKind == expectedResult;
	}

	static function typeKind(model:HlModule, index:Int):HlType {
		return switch model.typeAt(index) {
			case Simple(kind), Parameterized(kind, _): kind;
			case Abstract(_): HlType.Abstract;
			case Function(_, _): HlType.Fun;
			case Method(_, _): HlType.Method;
			case Object(_, _, _, _, _, _): HlType.Obj;
			case Structure(_, _, _, _, _): HlType.Struct;
			case Virtual(_): HlType.Virtual;
			case Enum(_, _, _): HlType.Enum;
		};
	}
}
