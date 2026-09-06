package compiler.types;

import compiler.types.Type.CompilerType;
import compiler.types.Type.NominalKind;

/** Explicit conversion required to assign one semantic type to another. */
enum ConversionPlan {
	Identity;
	AbstractCast;
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
		if (abstractConversion(actual, expected))
			return AbstractCast;
		if (!isAssignable(actual, expected))
			return Incompatible;
		return switch expected {
			case TDynamic: ToDynamic;
			case TInstance(kind, name, _):
				switch kind {
					case NominalKind.Interface:
						switch actual {
							case TInstance(actualKind, _, _):
								switch actualKind {
									case NominalKind.Class, NominalKind.Interface: ToInterface(name);
									default: Identity;
								}
							default: Identity;
						}
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
		if (abstractConversion(actual, expected))
			return true;
		return switch expected {
			case TDynamic: true;
			case TInstance(expectedKind, _, _):
				switch actual {
					case TInstance(actualKind, _, _):
						switch expectedKind {
							case NominalKind.Class:
								switch actualKind {
									case NominalKind.Class: nominalReaches(actual, expected);
									default: false;
								}
							case NominalKind.Interface:
								switch actualKind {
									case NominalKind.Class, NominalKind.Interface: nominalReaches(actual, expected);
									default: false;
								}
							default: false;
						}
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
			case TAbstract(name, arguments, _):
				switch right {
					case TAbstract(other, otherArguments, _): Std.string(name) == Std.string(other) && sameTypes(arguments, otherArguments);
					default: false;
				}
			case TTypeParameter(owner, name): switch right {
					case TTypeParameter(otherOwner, otherName): Std.string(owner) == Std.string(otherOwner) && name == otherName;
					default: false;
				};
			case TInstance(kind, name, arguments): sameNominal(right, kind, Std.string(name), arguments);
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
			case TInstance(otherKind, other, otherArguments): Std.string(kind) == Std.string(otherKind) && name == Std.string(other) && sameTypes(arguments,
					otherArguments);
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
			case TAbstract(_, _, representation): isReference(representation);
			case TString, TBytes, THlBytes, TDynamic, TNativeAbstract(_), TInstance(_, _, _), TAnonymous(_, _), TArray(_), TFunction(_, _), TMap(_, _): true;
			default: false;
		};

	function nominalReaches(actual:CompilerType, expected:CompilerType):Bool {
		return declarations.inheritance.reaches(actual, expected);
	}

	function abstractConversion(actual:CompilerType, expected:CompilerType):Bool {
		return switch expected {
			case TAbstract(name, arguments, representation):
				if (!declarations.abstracts.exists(name)) false; else {
					var decl = declarations.abstracts.get(name);
					var substitutions = abstractSubstitutions(decl.typeParameters, arguments),
						allowed = false;
					for (fromType in decl.fromTypes)
						if (equals(actual, declarations.resolve(fromType, decl.span, substitutions)))
							allowed = true;
					allowed;
				}
			default:
				switch actual {
					case TAbstract(name, arguments, representation):
						if (!declarations.abstracts.exists(name)) false; else {
							var decl = declarations.abstracts.get(name);
							var substitutions = abstractSubstitutions(decl.typeParameters, arguments),
								allowed = false;
							for (toType in decl.toTypes)
								if (equals(expected, declarations.resolve(toType, decl.span, substitutions)))
									allowed = true;
							allowed;
						}
					default: false;
				}
		};
	}

	static function abstractSubstitutions(parameters:Array<String>, arguments:Array<CompilerType>):Map<String, CompilerType> {
		var result:Map<String, CompilerType> = [];
		for (index in 0...parameters.length)
			result.set(parameters[index], arguments[index]);
		return result;
	}
}
