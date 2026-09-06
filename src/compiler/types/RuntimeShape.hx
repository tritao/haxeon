package compiler.types;

import compiler.types.Type.CompilerType;

/** Runtime calling/storage representation selected independently of semantic identity. */
enum abstract RuntimeShape(String) to String {
	var I32 = "i32";
	var F64 = "f64";
	var Bool = "bool";
	var Bytes = "bytes";
	var Ref = "ref";
	var Dynamic = "dyn";
}

class RuntimeShapes {
	public static function of(type:CompilerType):RuntimeShape
		return switch type {
			case TInt: RuntimeShape.I32;
			case TFloat: RuntimeShape.F64;
			case TBool: RuntimeShape.Bool;
			case TString, TBytes, THlBytes: RuntimeShape.Bytes;
			case TDynamic: RuntimeShape.Dynamic;
			default:
				if (TypeRelations.isReference(type)) RuntimeShape.Ref; else throw 'No runtime shape for ${SemanticSignature.type(type)}';
		};

	public static function representative(type:CompilerType):CompilerType
		return switch of(type) {
			case RuntimeShape.I32: TInt;
			case RuntimeShape.F64: TFloat;
			case RuntimeShape.Bool: TBool;
			case RuntimeShape.Bytes, RuntimeShape.Ref, RuntimeShape.Dynamic: TDynamic;
			default: throw 'Unknown runtime shape $type';
		};
}
