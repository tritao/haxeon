package compiler.ffi;

import compiler.ffi.CxxModel.CxxType;

/** Queries for C++ source types which need a generated adapter at the ABI boundary. */
class CxxTypeTools {
	public static function isStringView(type:CxxType):Bool
		return switch type {
			case CxxStringView: true;
			case CxxConst(element): isStringView(element);
			case _: false;
		};

	public static function hasStringView(types:Array<CxxType>):Bool {
		for (type in types)
			if (isStringView(type))
				return true;
		return false;
	}
}
