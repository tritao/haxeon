package compiler.types;

import compiler.core.InternalError;
import compiler.types.StructProperties;
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

	/** A nullable Int, Float, Bool or Int64 read as the plain type: null becomes the type's default (0, 0.0, false), as in Haxe. */
	UnwrapNullableDefault;

	Incompatible;
}

/** Two anonymous structures whose comparison is in progress. */
class FieldPair {
	public final left:Array<compiler.types.Type.AnonymousField>;
	public final right:Array<compiler.types.Type.AnonymousField>;

	public function new(left:Array<compiler.types.Type.AnonymousField>,
			right:Array<compiler.types.Type.AnonymousField>) {
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
		actual = Monomorphs.follow(actual);
		expected = Monomorphs.follow(expected);
		// A null where a type variable is expected is wrapped as a null of that type, which the variable's type replaces when it is
		// settled (`Some(null)`, before what the value meets fixes the parameter); it does not fill the variable.
		if (Monomorphs.isUnbound(expected) && actual.match(TNull))
			return WrapNullable;
		if (Monomorphs.isUnbound(actual) || Monomorphs.isUnbound(expected))
			return Identity;
		if (equals(actual, expected))
			return Identity;
		if (isNativeValue(actual) || isNativeValue(expected))
			return Incompatible;
		if ((switch (actual) {
			case TInt: true;
			default: false;
		}) && (switch (expected) {
			case TFloat: true;
			default: false;
		}))
			return IntToFloat;
		if ((switch (actual) {
			case TInt: true;
			default: false;
		}) && (switch (expected) {
			case TInt64: true;
			default: false;
		}))
			return IntToInt64;
		if ((switch (actual) {
			case TDynamic: true;
			default: false;
		}))
			return switch expected {
			case TNull, TVoid, TNever: Incompatible;
			default: FromDynamic;
		};
		if ((switch (actual) {
			case TNull: true;
			default: false;
		}) && acceptsNull(expected))
			return WrapNullable;
		if (abstractConversion(actual, expected))
			return AbstractCast;
		// Reading a nullable number as the number is a conversion toward an expected type, never part of assignability: a
		// conditional or array literal mixing Null<Int> and Int stays Null<Int>, so its null is kept.
		switch actual {
			case TNullable(element) if (hasNullDefault(expected) && !conversion(element, expected).match(Incompatible)):
				return UnwrapNullableDefault;
			default:
		}
		if (!isAssignable(actual, expected))
			return Incompatible;
		switch actual {
			case TNullable(element) if ((acceptsNull(expected) || isTypeParameter(expected))
				&& isAssignable(element, expected)):
				return UnwrapNullable;
			default:
		}
		return switch expected {
			case TDynamic: ToDynamic;
			// Dropping a path's write grant changes its semantic type while keeping
			// the same descriptor reference, just like a class reference upcast.
			case TKeyPath(_, _, _): ReferenceCast;
			case TInstance(kind, name, _):
				switch kind {
					case NominalKind.Interface:
						switch actual {
							case TInstance(actualKind, _, _):
								switch actualKind {
									case NominalKind.Class, NominalKind.Interface, NominalKind.Enum: ToInterface(name);
									default: Identity;
								}
							default: Identity;
						}
					default: ReferenceCast;
				}
			case TFunction(_, _, _): ReferenceCast;
			case TNullable(_): WrapNullable;
			default: Identity;
		};
	}

	public function isAssignable(actual:CompilerType, expected:CompilerType):Bool {
		actual = Monomorphs.follow(actual);
		expected = Monomorphs.follow(expected);
		// An empty type variable takes the other side's type where the value is converted (ConversionResolver.coerce).
		if (Monomorphs.isUnbound(actual) || Monomorphs.isUnbound(expected))
			return true;
		if ((switch (actual) {
			case TNever: true;
			default: false;
		}))
			return true;
		if (IterationProtocol.name(expected) != null)
			return (switch (actual) {
				case TNull: true;
				default: false;
			}) || TypeRelations.equals(actual, expected)
				|| IterationProtocol.conforms(declarations, this, actual, expected);
		if (isNativeValue(actual) || isNativeValue(expected))
			return equals(actual, expected);
		if (StructProperties.isConstraintType(expected))
			return false;
		if ((switch (actual) {
			case TNull: true;
			default: false;
		}) && acceptsNull(expected))
			return true;
		if (equals(actual, expected))
			return true;
		switch [actual, expected] {
			case [TKeyPath(root, value, true), TKeyPath(otherRoot, otherValue, false)]:
				return equals(root, otherRoot) && equals(value, otherValue);
			default:
		}
		if ((switch (actual) {
			case TDynamic: true;
			default: false;
		}))
			return switch expected {
			case TNull, TVoid, TNever: false;
			default: true;
		};
		if ((switch (actual) {
			case TNull: true;
			default: false;
		}) && acceptsNull(expected))
			return true;
		switch actual {
			// `Null<T>` is a `T`, as Haxe unifies them: what reading a null gives depends on what `T` stands for.
			case TNullable(element):
				if ((acceptsNull(expected) || isTypeParameter(expected)) && isAssignable(element, expected))
					return true;
			default:
		}
		if (abstractConversion(actual, expected))
			return true;
		switch actual {
			case TTypeParameter(_, _):
				// A type parameter's value is a value of each of its constraints (`T:Res` where a `Res` is expected), as Haxe unifies it.
				for (bound in declarations.typeParameterBounds(actual))
					if (isAssignable(bound, expected))
						return true;
			default:
		}
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
									case NominalKind.Enum: satisfiesConstraint(actual, expected);
									default: false;
								}
							default: false;
						}
					default: false;
				}
			case TAnonymous(_, _): anonymousReadOnlyWidening(actual, expected);
			case TNullable(expectedElement):
				switch actual {
					case TNull: true;
					default: equals(actual, expectedElement) || isAssignable(actual, expectedElement);
				}
			case TArray(expectedElement):
				switch actual {
					case TArray(actualElement): equals(actualElement, expectedElement)
						|| anonymousReadOnlyWidening(actualElement, expectedElement)
						|| sameNullableReference(actualElement, expectedElement);
					default: false;
				}
			case TIterator(expectedElement):
				switch actual {
					case TIterator(actualElement): equals(actualElement, expectedElement);
					default: false;
				}
			case TFunction(expectedArguments, expectedResult, expectedOptional):
				switch actual {
					case TFunction(actualArguments, actualResult, actualOptional):
						// A function whose argument is required cannot stand for one a call may omit it from (Haxe's `Cant_force_optional`).
						if (actualArguments.length != expectedArguments.length
							|| !FunctionTypes.acceptsOptional(actualOptional, expectedOptional)
							|| !convertsInFunction(actualResult, expectedResult)) false;
						else {
							var compatible = true;
							for (index in 0...actualArguments.length)
								if (!convertsInFunction(expectedArguments[index], actualArguments[index]))
									compatible = false;
							compatible;
						}
					default: false;
				}
			default: false;
		};
	}

	/**
	 * Whether a function's argument or result of type `actual` stands for `expected` in a function type: assignable, or an Int
	 * read as a Float (`Int->Void` takes a `Float->Void`), which Haxe unifies there. The function value is converted by an
	 * adapter (ConversionResolver.functionAdapter).
	 */
	public function convertsInFunction(actual:CompilerType, expected:CompilerType):Bool
		return isAssignable(actual, expected) || conversion(actual, expected).match(IntToFloat);

	/**
	 * Whether `left` and `right` are a reference type that holds null and its `Null<>`, either way round: one storage, so an array of
	 * one is an array of the other, as Haxe unifies them (`[].push(list.shift())` passed as an `Array<String>`). An enum is not one:
	 * its values may be stored inline.
	 */
	function sameNullableReference(left:CompilerType, right:CompilerType):Bool
		return switch [left, right] {
			case [TNullable(inner), _]: holdsNullItself(inner) && equals(inner, right);
			case [_, TNullable(inner)]: holdsNullItself(inner) && equals(left, inner);
			default: false;
		};

	function holdsNullItself(type:CompilerType):Bool
		return acceptsNull(type) && switch type {
			case TInstance(NominalKind.Enum, _, _): false;
			default: true;
		};

	/** A mutable structural field can be viewed through the same read-only field. */
	static function anonymousReadOnlyWidening(actual:CompilerType, expected:CompilerType):Bool {
		return switch [actual, expected] {
			case [TAnonymous(_, actualFields), TAnonymous(_, expectedFields)]:
				if (actualFields.length != expectedFields.length) false;
				else {
					var matches = true;
					for (target in expectedFields) {
						var found = false;
						for (source in actualFields)
							if (source.name == target.name) {
								found = source.optional == target.optional && (!source.isFinal || target.isFinal)
									&& equals(source.type, target.type);
								break;
							}
						if (!found) {
							matches = false;
							break;
						}
					}
					matches;
				}
			default: false;
		};
	}

	/** Check whether a type occurs inside another type's arguments without expanding nominal declarations. */
	static function isProperTypeSubterm(needle:CompilerType, haystack:CompilerType):Bool {
		var children:Array<CompilerType> = switch haystack {
			case TInstance(_, _, arguments) | TAbstract(_, arguments, _): arguments;
			case TArray(element) | TNullable(element) | TIterator(element): [element];
			case TMap(key, value): [key, value];
			case TKeyPath(root, value, _): [root, value];
			case TFunction(arguments, result, _): arguments.concat([result]);
			default: [];
		};
		for (child in children)
			if (equals(needle, child) || isProperTypeSubterm(needle, child))
				return true;
		return false;
	}

	/** Stop an expanding generic recursion when each old argument is embedded in its replacement. */
	static function typeArgumentsExpand(previous:CompilerType, current:CompilerType):Bool {
		return switch [previous, current] {
			case [TInstance(oldKind, oldName, oldArgs), TInstance(newKind, newName, newArgs)]
				if (oldKind == newKind && oldName == newName && oldArgs.length == newArgs.length):
				var expands = true;
				for (i in 0...oldArgs.length)
					if (!equals(oldArgs[i], newArgs[i]) && !isProperTypeSubterm(oldArgs[i], newArgs[i])) {
						expands = false;
						break;
					}
				expands;
			default: false;
		};
	}

	static function requiredDepth(depths:Map<String, Int>, key:String):Int {
		if (!depths.exists(key))
			throw new InternalError('Missing recursion depth "$key"');
		return depths.get(key);
	}

	/** Find the field closing a recursion through an anonymous structure. */
	public function recursiveAnonymousField(type:CompilerType, visiting:Map<String, Int>, field:Null<String>,
			anonymousDepth:Int = 0,
			nominalTypes:Null<Map<String, CompilerType>> = null):Null<String> {
		if (nominalTypes == null)
			nominalTypes = [];
		return switch type {
			case TNullable(element) | TArray(element): recursiveAnonymousField(element, visiting, field, anonymousDepth,
				nominalTypes);
			case TAnonymous(name, fields):
				var key = "anonymous:" + name;
				if (visiting.exists(key)) field;
				else {
					visiting.set(key, anonymousDepth);
					var found:Null<String> = null;
					for (entry in fields) {
						found = recursiveAnonymousField(entry.type, visiting, entry.name, anonymousDepth + 1,
							nominalTypes);
						if (found != null)
							break;
					}
					visiting.remove(key);
					found;
				}
			case TInstance(NominalKind.Class, name, arguments) if (isStruct(type)):
				var declaration = declarations.classes.get(name);
				var key = "struct:" + name,
					exactKey = key + ":" + compiler.semantic.SemanticSignature.type(type);
				if (declaration == null) null;
				else if (visiting.exists(exactKey)) anonymousDepth > requiredDepth(visiting,
					exactKey) ? field : null;
				else if (nominalTypes.exists(key)
					&& typeArgumentsExpand(nominalTypes.get(key), type)) anonymousDepth > requiredDepth(visiting, key)
					? field : null;
				else {
					var priorDepth = visiting.get(key),
						priorType = nominalTypes.get(key);
					visiting.set(key, anonymousDepth);
					nominalTypes.set(key, type);
					visiting.set(exactKey, anonymousDepth);
					var substitutions:Map<String, CompilerType> = [];
					for (index in 0...declaration.typeParameters.length) {
						var parameter = declaration.typeParameters[index],
							argument = index < arguments.length ? arguments[index] : TTypeParameter(name, parameter);
						substitutions.set(parameter, argument);
						substitutions.set(name + "." + parameter, argument);
					}
					var found:Null<String> = declaration.base == null
						? null : recursiveAnonymousField(declarations.resolve(declaration.base,
						declaration.span, substitutions), visiting, field, anonymousDepth, nominalTypes);
					if (found == null)
						for (entry in declaration.fields)
							if (!entry.isStatic && StructProperties.hasStorage(entry)) {
								var fieldType = declarations.types.fieldType(name, entry, substitutions);
								found = recursiveAnonymousField(fieldType, visiting, entry.name, anonymousDepth,
									nominalTypes);
								if (found != null)
									break;
							}
					visiting.remove(exactKey);
					if (priorDepth == null) {
						visiting.remove(key);
						nominalTypes.remove(key);
					} else {
						visiting.set(key, priorDepth);
						nominalTypes.set(key, priorType);
					}
					found;
				}
			case TInstance(NominalKind.Enum, name, arguments):
				var declaration = declarations.enums.get(name);
				var key = "enum:" + name,
					exactKey = key + ":" + compiler.semantic.SemanticSignature.type(type);
				if (declaration == null) null;
				else if (visiting.exists(exactKey)) anonymousDepth > requiredDepth(visiting,
					exactKey) ? field : null;
				else if (nominalTypes.exists(key)
					&& typeArgumentsExpand(nominalTypes.get(key), type)) anonymousDepth > requiredDepth(visiting, key)
					? field : null;
				else {
					var priorDepth = visiting.get(key),
						priorType = nominalTypes.get(key);
					visiting.set(key, anonymousDepth);
					nominalTypes.set(key, type);
					visiting.set(exactKey, anonymousDepth);
					var substitutions:Map<String, CompilerType> = [];
					for (index in 0...declaration.typeParameters.length) {
						var parameter = declaration.typeParameters[index],
							argument = index < arguments.length ? arguments[index] : TTypeParameter(name, parameter);
						substitutions.set(parameter, argument);
						substitutions.set(name + "." + parameter, argument);
					}
					var found:Null<String> = null;
					for (constructor in declaration.cases) {
						for (parameter in constructor.params) {
							found = recursiveAnonymousField(declarations.resolve(parameter.type, parameter.span,
								substitutions), visiting,
								parameter.name == null ? "payload" : parameter.name, anonymousDepth, nominalTypes);
							if (found != null)
								break;
						}
						if (found != null)
							break;
					}
					visiting.remove(exactKey);
					if (priorDepth == null) {
						visiting.remove(key);
						nominalTypes.remove(key);
					} else {
						visiting.set(key, priorDepth);
						nominalTypes.set(key, priorType);
					}
					found;
				}
			default: null;
		};
	}

	/** Check each field of a non-recursive anonymous structure. */
	function structuralCapability(actual:CompilerType, expected:CompilerType, visiting:Map<String, Bool>):Bool {
		return switch actual {
			case TAnonymous(name, fields):
				if (visiting.exists(name)) {
					switch expected {
						case TInstance(NominalKind.Interface, "Hashable", _): false;
						default: true;
					}
				} else {
					visiting.set(name, true);
					var valid = true;
					for (field in fields)
						if (!structuralCapability(field.type, expected, visiting)) {
							valid = false;
							break;
						}
					visiting.remove(name);
					valid;
				}
			case TNullable(element): structuralCapability(element, expected, visiting);
			case TArray(element): (switch expected {
					case TInstance(NominalKind.Interface, "Equatable", _): true;
					default: false;
				}) && structuralCapability(element, expected, visiting);
			default: satisfiesConstraint(actual, expected);
		};
	}

	/** Struct conformance in a generic constraint selects the specialized implementation. */
	public function satisfiesConstraint(actual:CompilerType, expected:CompilerType):Bool {
		actual = Monomorphs.follow(actual);
		expected = Monomorphs.follow(expected);
		switch actual {
			case TTypeParameter(_, _):
				return declarations.typeParameterSatisfies(actual, expected);
			case _:
		}
		var valueCapability = switch expected {
			case TInstance(NominalKind.Interface, name, _) if (name == "Equatable" || name == "Hashable"): true;
			default: false;
		};
		switch actual {
			case TAbstract(name, _, _) if (!valueCapability && declarations.enumAbstracts.exists(name)):
				var declaration = declarations.enumAbstracts.get(name);
				if (declaration.conformances != null)
					for (conformance in declaration.conformances) {
						var resolved = declarations.resolve(conformance, declaration.span);
						if (equals(resolved, expected) || nominalReaches(resolved, expected))
							return true;
					}
			default:
		}
		if (StructProperties.isConstraintType(expected))
			return StructProperties.satisfies(declarations, actual, representationConstraintName(expected));
		if (valueCapability && (switch actual {
			case TAnonymous(_, _): true;
			case TInstance(NominalKind.Class, _, _) | TInstance(NominalKind.Enum, _, _): switch expected {
					case TInstance(NominalKind.Interface, "Hashable", _): true;
					default: false;
				};
			default: false;
		}) && recursiveAnonymousField(actual, [], null) != null)
			return false;
		if (valueCapability)
			switch actual {
				case TInstance(NominalKind.Class, _, _) if (!isStruct(actual)):
					return false;
				case TInstance(NominalKind.Interface, _, _):
					return false;
				case TInt, TInt64, TBool, TFloat, TString, TNativeScalar(_), TKeyPath(_, _, _):
					return true;
				case TAbstract(name, _, representation):
					return !declarations.declaresEqualityOperator(name)
						&& satisfiesConstraint(representation, expected);
				case TNullable(element):
					return satisfiesConstraint(element, expected);
				case TAnonymous(_, _):
					return structuralCapability(actual, expected, []);
				case TArray(element):
					return (switch expected {
						case TInstance(NominalKind.Interface, "Equatable", _): true;
						default: false;
					}) && satisfiesConstraint(element, expected);
				case TInstance(NominalKind.Enum, name, _):
					var declaration = declarations.enums.get(name);
					if (declaration == null)
						return false;
					var hasPayload = false;
					for (constructor in declaration.cases)
						if (constructor.params.length > 0)
							hasPayload = true;
					if (!hasPayload)
						return true;
					if (declaration.conformances != null)
						for (conformance in declaration.conformances) {
							var resolved = declarations.resolve(conformance, declaration.span);
							if (equals(resolved, expected) || nominalReaches(resolved, expected))
								return true;
						}
					return false;
				default:
			}
		switch actual {
			case TInstance(NominalKind.Enum, name, arguments) if ((switch expected {
				case TInstance(NominalKind.Interface, _, _): true;
				default: false;
			})): var declaration = declarations.enums.get(name);
			if (declaration == null || declaration.conformances == null)
				return false;
			var substitutions:Map<String, CompilerType> = [];
			for (index in 0...declaration.typeParameters.length)
				substitutions.set(declaration.typeParameters[index],
					index < arguments.length ? arguments[index] : TTypeParameter(name,
					declaration.typeParameters[index]));
			for (conformance in declaration.conformances) {
				var resolved = declarations.resolve(conformance, declaration.span, substitutions);
				if (equals(resolved, expected) || nominalReaches(resolved, expected))
					return true;
			}
			return false;
			default:
		}
		if (isStructType(actual))
			switch expected {
				case TInstance(NominalKind.Interface, _, _):
					return nominalReaches(actual, expected);
				default:
			}
		return isAssignable(actual, expected);
	}

	public function constraintFailure(actual:CompilerType, expected:CompilerType):Null<String> {
		if (recursiveCapabilityFailure(actual, expected)) {
			var recursive = recursiveAnonymousField(actual, [], null);
			return 'recursive field "$recursive"; use a struct or class with explicit equals';
		}
		if (!StructProperties.isConstraintType(expected)
			|| StructProperties.satisfies(declarations, actual, representationConstraintName(expected)))
			return null;
		var constraintName = representationConstraintName(expected),
			property = constraintName == StructProperties.FLAT_TYPE_NAME ? "Flat" : "Portable",
			fieldPath = StructProperties.failurePath(declarations, actual, constraintName);
		return fieldPath == null ? 'type ${compiler.semantic.SemanticSignature.type(actual)} is not $property'
			: 'field "$fieldPath" is not $property';
	}

	public function recursiveCapabilityFailure(actual:CompilerType, expected:CompilerType):Bool {
		var capability = switch expected {
			case TInstance(NominalKind.Interface, name, _) if (name == "Equatable" || name == "Hashable"): true;
			default: false;
		};
		return capability && recursiveAnonymousField(actual, [], null) != null;
	}

	static function representationConstraintName(type:CompilerType):String
		return switch type {
			case TInstance(NominalKind.Interface, name, _): name;
			case _: throw new InternalError('Not a representation constraint: $type');
		};

	public static function equals(left:CompilerType, right:CompilerType):Bool
		return equalsWithin(left, right, null);

	/**
	 * `G<A>` is accepted where `G<Dynamic>` is expected, as in Haxe. Every instantiation of a generic class or interface shares
	 * one erased layout, so a `Dynamic` type argument stands for any argument; only the expected side may be `Dynamic`, and only
	 * as a whole argument. The other direction (`G<Dynamic>` where `G<A>` is expected) still needs a cast.
	 */
	public static function equalsWithDynamicArguments(actual:CompilerType, expected:CompilerType):Bool {
		switch actual {
			case TInstance(kind, name, arguments):
				switch expected {
					case TInstance(expectedKind, expectedName, expectedArguments):
						if (kind != expectedKind
							|| (name:String) != (expectedName:String) || arguments.length != expectedArguments.length)
							return false;
						var sawDynamic = false;
						for (index in 0...arguments.length) {
							if ((switch (expectedArguments[index]) {
								case TDynamic: true;
								default: false;
							})) {
								sawDynamic = true;
								continue;
							}
							if (!equals(arguments[index], expectedArguments[index]))
								return false;
						}
						return sawDynamic;
					default:
				}
			default:
		}
		return false;
	}

	/**
	 * `visiting` lists the pairs of anonymous structures being compared. A structure can contain itself, so meeting
	 * a pair again on the way down means the comparison has come full circle without finding a difference: it holds.
	 * The list is allocated only when the first anonymous structure is reached.
	 */
	static function equalsWithin(left:CompilerType, right:CompilerType, visiting:Null<Array<FieldPair>>):Bool {
		// A filled type variable is the type it holds; an empty one equals only itself.
		left = Monomorphs.follow(left);
		right = Monomorphs.follow(right);
		return switch left {
			case TAbstract(name, arguments, _):
				switch right {
					case TAbstract(other, otherArguments, _): (name:String) == (other:String)
						&& sameTypes(arguments, otherArguments, visiting);
					default: false;
				}
			case TTypeParameter(owner, name): switch right {
					case TTypeParameter(otherOwner, otherName): (owner:String) == (otherOwner:String)
						&& name == otherName;
					default: false;
				};
			case TNativeScalar(name):
				switch right {
					case TNativeScalar(other): name == other;
					default: false;
				};
			case TInstance(kind, name, arguments): sameNominal(right, kind, name, arguments, visiting);
			case TNativeAbstract(name): sameNativeAbstract(right, name);
			case TNullable(element): sameUnary(right, element, true, visiting);
			case TArray(element): sameUnary(right, element, false, visiting);
			case TIterator(element): switch right {
					case TIterator(other): equalsWithin(element, other, visiting);
					default: false;
				};
			case TMap(key, value):
				switch right {
					case TMap(otherKey, otherValue): equalsWithin(key, otherKey, visiting)
						&& equalsWithin(value, otherValue, visiting);
					default: false;
				}
			case TFunction(arguments, result, optional): sameFunction(right, arguments, result, optional, visiting);
			case TKeyPath(root, value, writable): switch right {
					case TKeyPath(otherRoot, otherValue, otherWritable): writable == otherWritable
						&& equalsWithin(root, otherRoot,
						visiting) && equalsWithin(value, otherValue, visiting);
					default: false;
				};
			case TAnonymous(_, fields):
				switch right {
					case TAnonymous(_, otherFields): sameAnonymousFields(fields, otherFields, visiting);
					default: false;
				}
			default: Type.enumEq(left, right);
		};
	}

	static function sameNominal(type:CompilerType, kind:compiler.types.Type.NominalKind, name:String,
			arguments:Array<CompilerType>,
			visiting:Null<Array<FieldPair>>):Bool
		return switch type {
			case TInstance(otherKind, other, otherArguments): kind == otherKind && name == (other:String)
				&& sameTypes(arguments, otherArguments, visiting);
			default: false;
		};

	static function sameTypes(left:Array<CompilerType>, right:Array<CompilerType>,
			visiting:Null<Array<FieldPair>>):Bool {
		if (left.length != right.length)
			return false;
		for (index in 0...left.length)
			if (!equalsWithin(left[index], right[index], visiting))
				return false;
		return true;
	}

	static function sameAnonymousFields(left:Array<compiler.types.Type.AnonymousField>,
			right:Array<compiler.types.Type.AnonymousField>,
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

	static function sameUnary(type:CompilerType, element:CompilerType, nullable:Bool,
			visiting:Null<Array<FieldPair>>):Bool
		return switch type {
			case TNullable(other) if (nullable): equalsWithin(element, other, visiting);
			case TArray(other) if (!nullable): equalsWithin(element, other, visiting);
			default: false;
		};

	static function sameFunction(type:CompilerType, arguments:Array<CompilerType>, result:CompilerType,
			optional:Array<Bool>, visiting:Null<Array<FieldPair>>):Bool
		return switch type {
			case TFunction(otherArguments, otherResult, otherOptional):
				if (arguments.length != otherArguments.length
					|| !FunctionTypes.sameOptional(optional, otherOptional)) false;
				else {
					var same = true;
					for (index in 0...arguments.length)
						if (!equalsWithin(arguments[index], otherArguments[index], visiting))
							same = false;
					same && equalsWithin(result, otherResult, visiting);
				}
			default: false;
		};

	public static function isReference(type:CompilerType):Bool
		return switch type {
			case TAbstract(_, _, representation): isReference(representation);
			case TString, TBytes, THlBytes, TDynamic, TNativeAbstract(_), TAnonymous(_, _), TArray(_), TIterator(_),
				TFunction(_, _, _), TMap(_, _),
				TKeyPath(_, _, _): true;
			case TInstance(kind, _, _): kind != NominalKind.NativeValue;
			default: false;
		};

	/** Reference types hold null, except value classes and structs: their values are copied into their storage. */
	static function isTypeParameter(type:CompilerType):Bool
		return switch type {
			case TTypeParameter(_, _): true;
			default: false;
		};

	function acceptsNull(type:CompilerType):Bool
		return isReference(type) && !isValueClass(type);

	/**
	 * Whether a nullable of `type` reads as `type` with a default for null, as Haxe does on static targets: `var x:Int = map.get(k)`
	 * is 0 when the key is absent. Structs and value classes have no such default and stay explicit.
	 */
	public static function hasNullDefault(type:CompilerType):Bool
		return switch type {
			case TInt | TFloat | TBool | TInt64: true;
			default: false;
		};

	/** Whether `type` is a value class or a struct with non-null value semantics. */
	public function isValueClass(type:CompilerType):Bool
		return switch type {
			case TInstance(NominalKind.Class, name, _):
				var declaration = declarations.classes.get(name);
				if (declaration == null) false;
				else {
					var found = declaration.isStruct == true;
					for (entry in declaration.metadata)
						if (entry.name == "value")
							found = true;
					found;
				}
			default: false;
		};

	function isStructType(type:CompilerType):Bool
		return switch type {
			case TInstance(NominalKind.Class, name, _): var declaration = declarations.classes.get(name);
				declaration != null && declaration.isStruct == true;
			default: false;
		};

	public inline function isStruct(type:CompilerType):Bool
		return isStructType(type);

	/** The runtime representation shared by transparent abstract layers. */
	public static function abstractRepresentation(type:CompilerType):CompilerType
		return switch type {
			case TAbstract(_, _, representation): abstractRepresentation(representation);
			default: type;
		};

	/** `Null<V>` for a value class V, which cannot be stored in an inline field. */
	public function isNullableValueClass(type:CompilerType):Bool
		return switch type {
			case TNullable(element): isValueClass(abstractRepresentation(element));
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
