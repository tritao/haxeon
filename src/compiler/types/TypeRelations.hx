package compiler.types;

import compiler.types.Type.CompilerType;
import compiler.types.Type.NominalKind;

/** Explicit conversion required to assign one semantic type to another. */
enum ConversionPlan {
	Identity;
	IntToFloat;
	IntToInt64;
	FromDynamic;
	AbstractCast;
	ReferenceCast;
	ToDynamic;
	ToInterface(name:String);
	WrapNullable;
	UnwrapNullable;
	Incompatible;
}

/** Two anonymous structures whose comparison is in progress. */
class FieldPair {
	public final left:Array<compiler.types.Type.AnonymousField>;
	public final right:Array<compiler.types.Type.AnonymousField>;

	public function new(left:Array<compiler.types.Type.AnonymousField>, right:Array<compiler.types.Type.AnonymousField>) {
		this.left = left;
		this.right = right;
	}
}

/** All semantic equality, assignability, and implicit-conversion decisions. */
class TypeRelations {
	final declarations:DeclarationIndex;

	public function new(declarations:DeclarationIndex)
		this.declarations = declarations;

	public function conversion(actual:CompilerType, expected:CompilerType):ConversionPlan {
		if (equals(actual, expected))
			return Identity;
		if (isNativeValue(actual) || isNativeValue(expected))
			return Incompatible;
		if (actual == TInt && expected == TFloat)
			return IntToFloat;
		if (actual == TInt && expected == TInt64)
			return IntToInt64;
		if (actual == TDynamic)
			return switch expected {
				case TNull, TVoid, TNever: Incompatible;
				default: FromDynamic;
			};
		if (actual == TNull && acceptsNull(expected))
			return WrapNullable;
		if (abstractConversion(actual, expected))
			return AbstractCast;
		if (!isAssignable(actual, expected))
			return Incompatible;
		switch actual {
			case TNullable(element) if (acceptsNull(expected) && isAssignable(element, expected)):
				return UnwrapNullable;
			default:
		}
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
					default: ReferenceCast;
				}
			case TFunction(_, _): ReferenceCast;
			case TNullable(_): WrapNullable;
			default: Identity;
		};
	}

	public function isAssignable(actual:CompilerType, expected:CompilerType):Bool {
		if (actual == TNever)
			return true;
		if (isNativeValue(actual) || isNativeValue(expected))
			return equals(actual, expected);
		if (actual == TNull && acceptsNull(expected))
			return true;
		if (equals(actual, expected))
			return true;
		if (actual == TDynamic)
			return switch expected {
				case TNull, TVoid, TNever: false;
				default: true;
			};
		if (actual == TNull && acceptsNull(expected))
			return true;
		switch actual {
			case TNullable(element):
				if (acceptsNull(expected) && isAssignable(element, expected))
					return true;
			default:
		}
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
					default: equals(actual, expectedElement) || isAssignable(actual, expectedElement);
				}
			case TArray(expectedElement):
				switch actual {
					case TArray(actualElement): equals(actualElement, expectedElement);
					default: false;
				}
			case TIterator(expectedElement):
				switch actual {
					case TIterator(actualElement): equals(actualElement, expectedElement);
					default: false;
				}
			case TFunction(expectedArguments, expectedResult):
				switch actual {
					case TFunction(actualArguments, actualResult):
						if (actualArguments.length != expectedArguments.length
							|| !isAssignable(actualResult, expectedResult)) false; else {
							var compatible = true;
							for (index in 0...actualArguments.length)
								if (!isAssignable(expectedArguments[index], actualArguments[index]))
									compatible = false;
							compatible;
						}
					default: false;
				}
			default: false;
		};
	}

	public static function equals(left:CompilerType, right:CompilerType):Bool
		return equalsWithin(left, right, null);

	/**
	 * `visiting` lists the pairs of anonymous structures being compared. A structure can contain itself, so meeting
	 * a pair again on the way down means the comparison has come full circle without finding a difference: it holds.
	 * The list is allocated only when the first anonymous structure is reached.
	 */
	static function equalsWithin(left:CompilerType, right:CompilerType, visiting:Null<Array<FieldPair>>):Bool
		return switch left {
			case TAbstract(name, arguments, _):
				switch right {
					case TAbstract(other, otherArguments, _): Std.string(name) == Std.string(other) && sameTypes(arguments, otherArguments, visiting);
					default: false;
				}
			case TTypeParameter(owner, name): switch right {
					case TTypeParameter(otherOwner, otherName): Std.string(owner) == Std.string(otherOwner) && name == otherName;
					default: false;
				};
			case TNativeScalar(name):
				switch right {
					case TNativeScalar(other): name == other;
					default: false;
				};
			case TInstance(kind, name, arguments): sameNominal(right, kind, Std.string(name), arguments, visiting);
			case TNativeAbstract(name): sameNativeAbstract(right, name);
			case TNullable(element): sameUnary(right, element, true, visiting);
			case TArray(element): sameUnary(right, element, false, visiting);
			case TIterator(element): switch right {
					case TIterator(other): equalsWithin(element, other, visiting);
					default: false;
				};
			case TMap(key, value):
				switch right {
					case TMap(otherKey, otherValue): equalsWithin(key, otherKey, visiting) && equalsWithin(value, otherValue, visiting);
					default: false;
				}
			case TFunction(arguments, result): sameFunction(right, arguments, result, visiting);
			case TAnonymous(_, fields):
				switch right {
					case TAnonymous(_, otherFields): sameAnonymousFields(fields, otherFields, visiting);
					default: false;
				}
			default: left == right;
		};

	static function sameNominal(type:CompilerType, kind:compiler.types.Type.NominalKind, name:String, arguments:Array<CompilerType>,
			visiting:Null<Array<FieldPair>>):Bool
		return switch type {
			case TInstance(otherKind, other, otherArguments): Std.string(kind) == Std.string(otherKind) && name == Std.string(other) && sameTypes(arguments,
					otherArguments, visiting);
			default: false;
		};

	static function sameTypes(left:Array<CompilerType>, right:Array<CompilerType>, visiting:Null<Array<FieldPair>>):Bool {
		if (left.length != right.length)
			return false;
		for (index in 0...left.length)
			if (!equalsWithin(left[index], right[index], visiting))
				return false;
		return true;
	}

	static function sameAnonymousFields(left:Array<compiler.types.Type.AnonymousField>, right:Array<compiler.types.Type.AnonymousField>,
			visiting:Null<Array<FieldPair>>):Bool {
		// Types resolved from one declaration share their field array, which settles most comparisons at once.
		if (left == right)
			return true;
		if (left.length != right.length)
			return false;
		var inProgress = visiting == null ? [] : visiting;
		for (pair in inProgress)
			if (pair.left == left && pair.right == right)
				return true;
		inProgress.push(new FieldPair(left, right));
		var same = true;
		for (field in left) {
			var found = false;
			for (candidate in right)
				if (candidate.name == field.name) {
					if (candidate.optional != field.optional
						|| candidate.isFinal != field.isFinal
						|| !equalsWithin(field.type, candidate.type, inProgress)) {
						same = false;
						break;
					}
					found = true;
				}
			if (!same)
				break;
			if (!found) {
				same = false;
				break;
			}
		}
		inProgress.pop();
		return same;
	}

	static function sameNativeAbstract(type:CompilerType, name:String):Bool
		return switch type {
			case TNativeAbstract(other): name == other;
			default: false;
		};

	static function sameUnary(type:CompilerType, element:CompilerType, nullable:Bool, visiting:Null<Array<FieldPair>>):Bool
		return switch type {
			case TNullable(other) if (nullable): equalsWithin(element, other, visiting);
			case TArray(other) if (!nullable): equalsWithin(element, other, visiting);
			default: false;
		};

	static function sameFunction(type:CompilerType, arguments:Array<CompilerType>, result:CompilerType, visiting:Null<Array<FieldPair>>):Bool
		return switch type {
			case TFunction(otherArguments, otherResult):
				if (arguments.length != otherArguments.length) false; else {
					var same = true;
					for (index in 0...arguments.length)
						if (!equalsWithin(arguments[index], otherArguments[index], visiting))
							same = false;
					same && equalsWithin(result, otherResult, visiting)
					;
				}
			default: false;
		};

	public static function isReference(type:CompilerType):Bool
		return switch type {
			case TAbstract(_, _, representation): isReference(representation);
			case TString, TBytes, THlBytes, TDynamic, TNativeAbstract(_), TAnonymous(_, _), TArray(_), TIterator(_), TFunction(_, _), TMap(_, _): true;
			case TInstance(kind, _, _): kind != NominalKind.NativeValue;
			default: false;
		};

	/** Reference types hold null, except @:value classes: their instances are stored inline in fields and are never null. */
	function acceptsNull(type:CompilerType):Bool
		return isReference(type) && !isValueClass(type);

	/** Whether `type` is a class declared `@:value`, which is a plain (non-record) value structure. */
	public function isValueClass(type:CompilerType):Bool
		return switch type {
			case TInstance(NominalKind.Class, name, _):
				var declaration = declarations.classes.get(name);
				if (declaration == null) false; else {
					var found = false;
					for (entry in declaration.metadata)
						if (entry.name == "value")
							found = true;
					found;
				}
			default: false;
		};

	/** `Null<V>` for a value class V, which cannot be stored in an inline field. */
	public function isNullableValueClass(type:CompilerType):Bool
		return switch type {
			case TNullable(element): isValueClass(element);
			default: false;
		};

	static function isNativeValue(type:CompilerType):Bool
		return switch type {
			case TInstance(NominalKind.NativeValue, _, _): true;
			default: false;
		};

	function nominalReaches(actual:CompilerType, expected:CompilerType):Bool {
		return declarations.inheritance.reaches(actual, expected);
	}

	function abstractConversion(actual:CompilerType, expected:CompilerType):Bool {
		return declarations.conversions.allows(actual, expected);
	}
}
