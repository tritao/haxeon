package compiler.types;

import compiler.types.Type.CompilerType;

/** Explicit conversion required to assign one semantic type to another. */
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
		return switch expected {
			case TDynamic: ToDynamic;
			case TInstance(Interface, name, []):
				switch actual {
					case TInstance(Class, _, []), TInstance(Interface, _, []): ToInterface(name);
					default: Identity;
				}
			case TNullable(_): WrapNullable;
			default: Identity;
		};
	}

	public function isAssignable(actual:CompilerType, expected:CompilerType):Bool {
		if (actual == TNever)
			return true;
		if (equals(actual, expected))
			return true;
		return switch expected {
			case TDynamic: true;
			case TInstance(Class, expectedName, []):
				switch actual {
					case TInstance(Class, actualName, []): classReaches(actualName, expectedName);
					default: false;
				}
			case TInstance(Interface, expectedName, []):
				switch actual {
					case TInstance(Class, actualName, []): classReaches(actualName, expectedName);
					case TInstance(Interface, actualName, []): interfaceReaches(actualName, expectedName);
					default: false;
				}
			case TNullable(expectedElement):
				switch actual {
					case TNull: true;
					default: isReference(actual) && (equals(actual, expectedElement) || isAssignable(actual, expectedElement));
				}
			case TArray(expectedElement):
				switch actual {
					case TArray(actualElement): equals(actualElement, expectedElement);
					default: false;
				}
			default: false;
		};
	}

	public static function equals(left:CompilerType, right:CompilerType):Bool
		return switch left {
			case TTypeParameter(owner, name): switch right {
					case TTypeParameter(otherOwner, otherName): owner == otherOwner && name == otherName;
					default: false;
				};
			case TInstance(Class, name, arguments): sameNominal(right, Class, name, arguments);
			case TInstance(Interface, name, arguments): sameNominal(right, Interface, name, arguments);
			case TInstance(Enum, name, arguments): sameEnum(right, name, arguments);
			case TNativeAbstract(name): sameNativeAbstract(right, name);
			case TNullable(element): sameUnary(right, element, true);
			case TArray(element): sameUnary(right, element, false);
			case TMap(key, value):
				switch right {
					case TMap(otherKey, otherValue): equals(key, otherKey) && equals(value, otherValue);
					default: false;
				}
			case TFunction(arguments, result): sameFunction(right, arguments, result);
			case TAnonymous(name, _):
				switch right {
					case TAnonymous(other, _): name == other;
					default: false;
				}
			default: left == right;
		};

	static function sameNominal(type:CompilerType, kind:compiler.types.Type.NominalKind, name:String, arguments:Array<CompilerType>):Bool
		return switch type {
			case TInstance(otherKind, other, otherArguments): kind == otherKind && name == other && sameTypes(arguments, otherArguments);
			default: false;
		};

	static function sameEnum(type:CompilerType, name:String, arguments:Array<CompilerType>):Bool
		return switch type {
			case TInstance(Enum, other, otherArguments): name == other && sameTypes(arguments, otherArguments);
			default: false;
		};

	static function sameTypes(left:Array<CompilerType>, right:Array<CompilerType>):Bool {
		if (left.length != right.length)
			return false;
		for (index in 0...left.length)
			if (!equals(left[index], right[index]))
				return false;
		return true;
	}

	static function sameNativeAbstract(type:CompilerType, name:String):Bool
		return switch type {
			case TNativeAbstract(other): name == other;
			default: false;
		};

	static function sameUnary(type:CompilerType, element:CompilerType, nullable:Bool):Bool
		return switch type {
			case TNullable(other) if (nullable): equals(element, other);
			case TArray(other) if (!nullable): equals(element, other);
			default: false;
		};

	static function sameFunction(type:CompilerType, arguments:Array<CompilerType>, result:CompilerType):Bool
		return switch type {
			case TFunction(otherArguments, otherResult):
				if (arguments.length != otherArguments.length) false; else {
					var same = true;
					for (index in 0...arguments.length)
						if (!equals(arguments[index], otherArguments[index]))
							same = false;
					same && equals(result, otherResult)
					;
				}
			default: false;
		};

	public static function isReference(type:CompilerType):Bool
		return switch type {
			case TString, TBytes, THlBytes, TDynamic, TNativeAbstract(_), TInstance(Class, _, []), TInstance(Interface, _, []), TInstance(Enum, _, _),
				TAnonymous(_, _), TArray(_), TFunction(_, _), TMap(_, _): true;
			default: false;
		};

	function classReaches(actual:String, expected:String):Bool {
		if (actual == expected)
			return true;
		if (!declarations.classes.exists(actual))
			return interfaceReaches(actual, expected);
		var decl = declarations.classes.get(actual), base = decl.base;
		if (base != null && classReaches(base, expected))
			return true;
		for (name in decl.interfaces)
			if (interfaceReaches(name, expected))
				return true;
		return false;
	}

	function interfaceReaches(actual:String, expected:String):Bool {
		if (actual == expected)
			return true;
		if (!declarations.interfaces.exists(actual))
			return false;
		var decl = declarations.interfaces.get(actual);
		for (base in decl.bases)
			if (interfaceReaches(base, expected))
				return true;
		return false;
	}
}
