package compiler.types;

import compiler.types.Type.CompilerType;

enum ConversionPlan {
	Identity;
	ToDynamic;
	ToInterface(name:String);
	WrapNullable;
	Incompatible;
}

/** All semantic equality, assignability, and implicit-conversion decisions. */
class TypeRelations {
	final declarations:DeclarationIndex;

	public function new(declarations:DeclarationIndex)
		this.declarations = declarations;

	public function conversion(actual:CompilerType, expected:CompilerType):ConversionPlan {
		if (equals(actual, expected))
			return Identity;
		if (!isAssignable(actual, expected))
			return Incompatible;
		return switch [actual, expected] {
			case [_, TDynamic]: ToDynamic;
			case [TClass(_), TInterface(name)], [TInterface(_), TInterface(name)]: ToInterface(name);
			case [_, TNullable(_)]: WrapNullable;
			default: Identity;
		};
	}

	public function isAssignable(actual:CompilerType, expected:CompilerType):Bool {
		if (actual == TNever)
			return true;
		if (equals(actual, expected))
			return true;
		return switch [actual, expected] {
			case [_, TDynamic]: true;
			case [TClass(actualName), TClass(expectedName)]: classReaches(actualName, expectedName);
			case [TClass(actualName), TInterface(expectedName)]: classReaches(actualName, expectedName);
			case [TInterface(actualName), TInterface(expectedName)]: interfaceReaches(actualName, expectedName);
			case [TNull, TNullable(_)]: true;
			case [actual, TNullable(expected)]: isReference(actual) && (equals(actual, expected) || isAssignable(actual, expected));
			case [TArray(actualElement), TArray(expectedElement)]: equals(actualElement, expectedElement);
			default: false;
		};
	}

	public static function equals(left:CompilerType, right:CompilerType):Bool
		return switch [left, right] {
			case [TClass(a), TClass(b)], [TInterface(a), TInterface(b)], [TEnum(a), TEnum(b)], [TNativeAbstract(a), TNativeAbstract(b)]: a == b;
			case [TNullable(a), TNullable(b)], [TArray(a), TArray(b)]: equals(a, b);
			case [TMap(ak, av), TMap(bk, bv)]: equals(ak, bk) && equals(av, bv);
			case [TFunction(aa, ar), TFunction(ba, br)]: aa.length == ba.length && [
					for (i in 0...aa.length)
						equals(aa[i], ba[i])
				].indexOf(false) < 0 && equals(ar, br);
			case [TAnonymous(a, _), TAnonymous(b, _)]: a == b;
			default: left == right;
		};

	public static function isReference(type:CompilerType):Bool
		return switch type {
			case TString, TDynamic, TNativeAbstract(_), TClass(_), TInterface(_), TAnonymous(_, _), TArray(_), TFunction(_), TMap(_, _): true;
			default: false;
		};

	function classReaches(actual:String, expected:String):Bool {
		if (actual == expected)
			return true;
		var decl = declarations.classes.get(actual);
		if (decl == null)
			return interfaceReaches(actual, expected);
		if (decl.base != null && classReaches(decl.base, expected))
			return true;
		for (name in decl.interfaces)
			if (interfaceReaches(name, expected))
				return true;
		return false;
	}

	function interfaceReaches(actual:String, expected:String):Bool {
		if (actual == expected)
			return true;
		var decl = declarations.interfaces.get(actual);
		if (decl == null)
			return false;
		for (base in decl.bases)
			if (interfaceReaches(base, expected))
				return true;
		return false;
	}
}
