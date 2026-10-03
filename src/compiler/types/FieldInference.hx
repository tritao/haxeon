package compiler.types;

import compiler.syntax.Ast.AstExpression;
import compiler.syntax.Ast.AstField;
import compiler.syntax.Ast.AstType;
import compiler.Diagnostic;
import compiler.Diagnostic.CompileError;

/** Resolves field annotations before class signatures and bodies are typed. */
class FieldInference {
	public static function parsedType(field:AstField):AstType {
		var declaredType = field.type;
		if (declaredType != null)
			return declaredType;
		var initializer = field.initializer;
		if (initializer == null)
			throw new CompileError(new Diagnostic("E1002", 'Cannot infer type of field "${field.name}" without an initializer', field.span));
		return switch initializer {
			case IntegerLiteral(_, _): IntType;
			case FloatLiteral(_, _): FloatType;
			case Negate(value, _): isLiteralOperand(value) ? negatedType(field, value) : InferredType;
			case StringLiteral(_, _): StringType;
			case Add(left, right, _) if (isConstantString(left) && isConstantString(right)): StringType;
			case BoolLiteral(_, _): BoolType;
			case Add(_, _, _), Sub(_, _, _), Mul(_, _, _), Div(_, _, _), Mod(_, _, _), BitAnd(_, _, _), BitXor(_, _, _), BitOr(_, _, _), ShiftLeft(_, _, _),
				ShiftRight(_, _, _), UnsignedShiftRight(_, _, _):
				// Operands naming static fields or calls are typed once declarations resolve.
				hasOnlyLiteralOperands(initializer) ? constantNumericType(field, initializer) : InferredType;
			case New(typeName, _, _): NamedType(typeName);
			case NewGeneric(typeName, typeArguments, _, _): AppliedType(typeName, typeArguments);
			case NewArray(element, _, _): ArrayType(element);
			case ArrayLiteral(values, _): arrayLiteralType(field, values);
			case NewMap(key, value, _): MapType(key, value);
			case Call(_, _, _): InferredType;
			case Member(_, _, _): InferredType;
			case Variable(name, _) if (name.indexOf(".") > 0): InferredType;
			default:
				throw new CompileError(new Diagnostic("E1002", 'Cannot infer type of field "${field.name}" from this initializer', field.span));
		};
	}

	static function arrayLiteralType(field:AstField, values:Array<AstExpression>):AstType {
		if (values.length == 0)
			throw new CompileError(new Diagnostic("E1002",
				'Cannot infer type of empty array field "${field.name}"; a field\'s type is part of its class, so annotate it, as in `var ${field.name}:Array<T> = [];`',
				field.span));
		var element = literalElementType(values[0]);
		if (element == null)
			throw new CompileError(new Diagnostic("E1002", 'Cannot infer type of field "${field.name}" from this array initializer', field.span));
		for (index in 1...values.length)
			if (literalElementType(values[index]) != element)
				throw new CompileError(new Diagnostic("E1002", 'Array initializer for field "${field.name}" has mixed element types', field.span));
		return ArrayType(element);
	}

	static function literalElementType(value:AstExpression):Null<AstType>
		return switch value {
			case IntegerLiteral(_, _): IntType;
			case FloatLiteral(_, _): FloatType;
			case StringLiteral(_, _): StringType;
			case BoolLiteral(_, _): BoolType;
			default: null;
		};

	static function constantNumericType(field:AstField, expression:AstExpression):AstType {
		var inferred:Null<AstType> = switch expression {
			case IntegerLiteral(_, _): IntType;
			case FloatLiteral(_, _): FloatType;
			case Negate(value, _): nullableNumericType(value);
			case Div(left, right, _): numericPair(left, right) == null ? null : FloatType;
			case Add(left, right, _), Sub(left, right, _), Mul(left, right, _): numericPair(left, right);
			case Mod(left, right, _), BitAnd(left, right, _), BitXor(left, right, _), BitOr(left, right, _), ShiftLeft(left, right, _),
				ShiftRight(left, right, _), UnsignedShiftRight(left, right, _):
				var pair = numericPair(left, right);
				pair == IntType ? IntType : null;
			default: null;
		};
		if (inferred == null) {
			if (mentionsBareVariable(expression))
				return InferredType;
			throw new CompileError(new Diagnostic("E1002", 'Cannot infer type of field "${field.name}" from this initializer', field.span));
		}
		return inferred;
	}

	/** True when a numeric expression refers to a bare name, such as a sibling static constant, that only the class context can type. */
	static function mentionsBareVariable(expression:AstExpression):Bool
		return switch expression {
			case Variable(name, _): name.indexOf(".") < 0;
			case Negate(value, _): mentionsBareVariable(value);
			case Add(left, right, _), Sub(left, right, _), Mul(left, right, _), Div(left, right, _), Mod(left, right, _), BitAnd(left, right, _),
				BitXor(left, right, _), BitOr(left, right, _), ShiftLeft(left, right, _), ShiftRight(left, right, _), UnsignedShiftRight(left, right, _):
				mentionsBareVariable(left) || mentionsBareVariable(right);
			default: false;
		};

	/**
	 * Types a numeric constant expression that names sibling static fields (`1.0 / DT`) by resolving those fields
	 * first. Null when any operand is not a plain `Int` or `Float` constant, leaving the caller to report it.
	 */
	static function siblingNumericType(expression:AstExpression, owner:String, classes:Map<String, compiler.syntax.Ast.AstClass>, aliases:Map<String, String>,
			enums:Map<String, compiler.syntax.Ast.AstEnum>, enumAbstracts:Map<String, compiler.syntax.Ast.AstEnumAbstract>,
			resolving:Map<String, Bool>):Null<AstType> {
		inline function operand(value:AstExpression)
			return siblingNumericType(value, owner, classes, aliases, enums, enumAbstracts, resolving);
		return switch expression {
			case IntegerLiteral(_, _): IntType;
			case FloatLiteral(_, _): FloatType;
			case Variable("Math.PI" | "Math.NaN" | "Math.POSITIVE_INFINITY" | "Math.NEGATIVE_INFINITY", _): FloatType;
			case Negate(value, _): operand(value);
			case Variable(name, _) if (name.indexOf(".") < 0): var ownerClass = classes.get(owner),
					target:Null<AstField> = null; if (ownerClass != null) for (candidate in ownerClass.fields) if (candidate.isStatic && candidate.name == name) target = candidate; if (target == null
					|| resolving.exists(owner + "." + name)) return null; var type = resolveField(target, owner, classes, aliases, enums, enumAbstracts,
					resolving); type == IntType || type == FloatType ? type : null;
			case Div(left, right, _): operand(left) == null || operand(right) == null ? null : FloatType;
			case Add(left, right, _), Sub(left, right, _), Mul(left, right, _): var leftType = operand(left),
					rightType = operand(right); leftType == null || rightType == null ? null : leftType == FloatType
				|| rightType == FloatType ? FloatType : IntType;
			case Mod(left, right, _), BitAnd(left, right, _), BitXor(left, right, _), BitOr(left, right, _), ShiftLeft(left, right, _),
				ShiftRight(left, right, _), UnsignedShiftRight(left, right, _): operand(left) == IntType && operand(right) == IntType ? IntType : null;
			default: null;
		};
	}

	static function nullableNumericType(expression:AstExpression):Null<AstType>
		return switch expression {
			case IntegerLiteral(_, _): IntType;
			case FloatLiteral(_, _): FloatType;
			case Variable("Math.PI" | "Math.NaN" | "Math.POSITIVE_INFINITY" | "Math.NEGATIVE_INFINITY", _): FloatType;
			case Negate(value, _): nullableNumericType(value);
			case Div(left, right, _): numericPair(left, right) == null ? null : FloatType;
			case Add(left, right, _), Sub(left, right, _), Mul(left, right, _): numericPair(left, right);
			case Mod(left, right, _), BitAnd(left, right, _), BitXor(left, right, _), BitOr(left, right, _), ShiftLeft(left, right, _),
				ShiftRight(left, right, _), UnsignedShiftRight(left, right, _): numericPair(left, right) == IntType ? IntType : null;
			default: null;
		};

	static function numericPair(left:AstExpression, right:AstExpression):Null<AstType> {
		var leftType = nullableNumericType(left),
			rightType = nullableNumericType(right);
		if (leftType == null || rightType == null)
			return null;
		return leftType == FloatType || rightType == FloatType ? FloatType : IntType;
	}

	/**
	 * `enums` and `enumAbstracts` let an initializer that names an enum constructor or an enum abstract value, such
	 * as `Kind.Rapid`, give the field that enum's (or abstract's) type.
	 */
	public static function resolvedType(field:AstField, owner:String, classes:Map<String, compiler.syntax.Ast.AstClass>, aliases:Map<String, String>,
			?enums:Map<String, compiler.syntax.Ast.AstEnum>, ?enumAbstracts:Map<String, compiler.syntax.Ast.AstEnumAbstract>):AstType {
		return resolveField(field, owner, classes, aliases, enums == null ? [] : enums, enumAbstracts == null ? [] : enumAbstracts, []);
	}

	static function resolveField(field:AstField, owner:String, classes:Map<String, compiler.syntax.Ast.AstClass>, aliases:Map<String, String>,
			enums:Map<String, compiler.syntax.Ast.AstEnum>, enumAbstracts:Map<String, compiler.syntax.Ast.AstEnumAbstract>,
			resolving:Map<String, Bool>):AstType {
		var inferred = parsedType(field);
		if (inferred != InferredType)
			return inferred;
		var key = owner + "." + field.name;
		if (resolving.exists(key))
			throw new CompileError(new Diagnostic("E1002", 'Cyclic field type inference through "$key"', field.span));
		resolving.set(key, true);
		var enumType = enumConstructorType(field.initializer, owner, classes, aliases, enums, enumAbstracts);
		if (enumType != null) {
			resolving.remove(key);
			return enumType;
		}
		if (isOperator(field.initializer)) {
			var operatorType = operandType(field.initializer, owner, classes, aliases, enums, enumAbstracts, resolving);
			if (operatorType == null)
				throw new CompileError(new Diagnostic("E1002", 'Cannot infer type of field "${field.name}" from this initializer', field.span));
			resolving.remove(key);
			return operatorType;
		}
		var reference = staticFieldReference(field.initializer);
		if (reference == null) {
			var callType = staticCallResult(field.initializer, owner, classes, aliases);
			if (callType != null) {
				resolving.remove(key);
				return callType;
			}
			var numericType = siblingNumericType(field.initializer, owner, classes, aliases, enums, enumAbstracts, resolving);
			if (numericType != null) {
				resolving.remove(key);
				return numericType;
			}
			throw new CompileError(new Diagnostic("E1002", 'Cannot infer type of field "${field.name}" from this initializer', field.span));
		}
		var targetOwner = resolveOwner(reference.owner, owner, classes, aliases),
			targetClass = classes.get(targetOwner),
			target:Null<AstField> = null;
		if (targetClass != null)
			for (candidate in targetClass.fields)
				if (candidate.isStatic && candidate.name == reference.name)
					target = candidate;
		if (target == null)
			throw new CompileError(new Diagnostic("E1002",
				'Cannot infer type of field "${field.name}" from unknown static field "${reference.owner}.${reference.name}"', field.span));
		var result = resolveField(target, targetOwner, classes, aliases, enums, enumAbstracts, resolving);
		resolving.remove(key);
		return result;
	}

	/**
	 * The enum named by an initializer that is one of its constructors (`Kind.Rapid`, `Kind.Feed(3)`), or the
	 * enum abstract named by one of its values (`Mode.Fast`); null when it is neither. A class of that name
	 * takes precedence, and a generic enum is left alone: its type arguments would have to come from the
	 * constructor's arguments.
	 */
	static function enumConstructorType(expression:AstExpression, currentOwner:String, classes:Map<String, compiler.syntax.Ast.AstClass>,
			aliases:Map<String, String>, enums:Map<String, compiler.syntax.Ast.AstEnum>,
			enumAbstracts:Map<String, compiler.syntax.Ast.AstEnumAbstract>):Null<AstType> {
		var path:Null<String> = null, hasArguments = false;
		switch expression {
			case Member(Variable(owner, _), name, _):
				path = owner + "." + name;
			case Variable(value, _):
				path = value;
			case Call(name, _, _):
				path = name;
				hasArguments = true;
			default:
		}
		if (path == null)
			return null;
		var separator = path.lastIndexOf(".");
		if (separator <= 0)
			return null;
		var written = path.substring(0, separator),
			caseName = path.substring(separator + 1);
		if (classes.exists(resolveOwner(written, currentOwner, classes, aliases)))
			return null;
		if (!hasArguments) {
			var abstractName = resolveDeclaration(written, currentOwner, aliases, enumAbstracts);
			if (abstractName != null) {
				var declaration = enumAbstracts.get(abstractName);
				if (declaration == null)
					return null;
				for (value in declaration.values)
					if (value.name == caseName)
						return NamedType(written);
				return null;
			}
		}
		var resolved = resolveDeclaration(written, currentOwner, aliases, enums);
		if (resolved == null)
			return null;
		var declaration = enums.get(resolved);
		if (declaration == null)
			return null;
		if (declaration.typeParameters.length > 0)
			return null;
		for (enumCase in declaration.cases)
			if (enumCase.name == caseName && (enumCase.params.length == 0) != hasArguments)
				return NamedType(written);
		return null;
	}

	static function resolveDeclaration<T>(name:String, currentOwner:String, aliases:Map<String, String>, enums:Map<String, T>):Null<String> {
		if (aliases.exists(name) && enums.exists(aliases.get(name)))
			return aliases.get(name);
		if (enums.exists(name))
			return name;
		var separator = currentOwner.lastIndexOf("."),
			local = separator < 0 ? name : currentOwner.substring(0, separator + 1) + name;
		if (enums.exists(local))
			return local;
		var found:Null<String> = null;
		for (candidate in enums.keys())
			if (candidate == name || StringTools.endsWith(candidate, "." + name)) {
				if (found != null)
					return null;
				found = candidate;
			}
		return found;
	}

	static function isOperator(expression:AstExpression):Bool
		return switch expression {
			case Negate(_, _), Add(_, _, _), Sub(_, _, _), Mul(_, _, _), Div(_, _, _), Mod(_, _, _), BitAnd(_, _, _), BitXor(_, _, _), BitOr(_, _, _),
				ShiftLeft(_, _, _), ShiftRight(_, _, _), UnsignedShiftRight(_, _, _): true;
			default: false;
		};

	static function isLiteralOperand(expression:AstExpression):Bool
		return switch expression {
			case IntegerLiteral(_, _), FloatLiteral(_, _), StringLiteral(_, _): true;
			default: false;
		};

	/** Whether every leaf of an operator expression is a literal, so it types without declarations. */
	static function hasOnlyLiteralOperands(expression:AstExpression):Bool
		return switch expression {
			case Negate(value, _): hasOnlyLiteralOperands(value);
			case Add(left, right, _), Sub(left, right, _), Mul(left, right, _), Div(left, right, _), Mod(left, right, _), BitAnd(left, right, _),
				BitXor(left, right, _), BitOr(left, right, _), ShiftLeft(left, right, _), ShiftRight(left, right, _), UnsignedShiftRight(left, right, _):
				hasOnlyLiteralOperands(left) && hasOnlyLiteralOperands(right);
			default: isLiteralOperand(expression);
		};

	/**
	 * Type of an operator initializer whose operands are literals, static fields (qualified, or
	 * unqualified in the owning class) or static calls, with the literal rules: `/` gives Float,
	 * `%` and the bit operators need Int, `+` joins two Strings. Null when an operand is anything else.
	 */
	static function operandType(expression:AstExpression, owner:String, classes:Map<String, compiler.syntax.Ast.AstClass>, aliases:Map<String, String>,
			enums:Map<String, compiler.syntax.Ast.AstEnum>, enumAbstracts:Map<String, compiler.syntax.Ast.AstEnumAbstract>,
			resolving:Map<String, Bool>):Null<AstType> {
		function numeric(type:Null<AstType>):Bool
			return type == IntType || type == FloatType;
		function pair(left:AstExpression, right:AstExpression):Null<AstType> {
			var leftType = operandType(left, owner, classes, aliases, enums, enumAbstracts, resolving),
				rightType = operandType(right, owner, classes, aliases, enums, enumAbstracts, resolving);
			if (!numeric(leftType) || !numeric(rightType))
				return null;
			return leftType == FloatType || rightType == FloatType ? FloatType : IntType;
		}
		return switch expression {
			case IntegerLiteral(_, _): IntType;
			case FloatLiteral(_, _): FloatType;
			case StringLiteral(_, _): StringType;
			case Negate(value, _):
				var type = operandType(value, owner, classes, aliases, enums, enumAbstracts, resolving);
				numeric(type) ? type : null;
			case Add(left, right, _):
				var leftType = operandType(left, owner, classes, aliases, enums, enumAbstracts, resolving),
					rightType = operandType(right, owner, classes, aliases, enums, enumAbstracts, resolving);
				if (leftType == StringType && rightType == StringType) StringType; else if (numeric(leftType) && numeric(rightType)) (leftType == FloatType
					|| rightType == FloatType ? FloatType : IntType); else null;
			case Div(left, right, _): pair(left, right) == null ? null : FloatType;
			case Sub(left, right, _), Mul(left, right, _): pair(left, right);
			case Mod(left, right, _), BitAnd(left, right, _), BitXor(left, right, _), BitOr(left, right, _), ShiftLeft(left, right, _),
				ShiftRight(left, right, _), UnsignedShiftRight(left, right, _):
				pair(left, right) == IntType ? IntType : null;
			case Call(_, _, _): staticCallResult(expression, owner, classes, aliases);
			default: staticFieldType(expression, owner, classes, aliases, enums, enumAbstracts, resolving);
		};
	}

	/** Type of a static field an operand names, qualified or as a bare name in the owning class. */
	static function staticFieldType(expression:AstExpression, owner:String, classes:Map<String, compiler.syntax.Ast.AstClass>, aliases:Map<String, String>,
			enums:Map<String, compiler.syntax.Ast.AstEnum>, enumAbstracts:Map<String, compiler.syntax.Ast.AstEnumAbstract>,
			resolving:Map<String, Bool>):Null<AstType> {
		var reference = staticFieldReference(expression);
		if (reference == null)
			reference = switch expression {
				case Variable(name, _) if (name.indexOf(".") < 0): {owner: owner, name: name};
				default: null;
			};
		if (reference == null)
			return null;
		var targetOwner = resolveOwner(reference.owner, owner, classes, aliases),
			targetClass = classes.get(targetOwner);
		if (targetClass == null)
			return null;
		for (candidate in targetClass.fields)
			if (candidate.isStatic && candidate.name == reference.name)
				return resolveField(candidate, targetOwner, classes, aliases, enums, enumAbstracts, resolving);
		return null;
	}

	static function staticCallResult(expression:AstExpression, currentOwner:String, classes:Map<String, compiler.syntax.Ast.AstClass>,
			aliases:Map<String, String>):Null<AstType> {
		var call = switch expression {
			case Call(name, _, _): name;
			default: null;
		};
		if (call == null)
			return null;
		var separator = call.lastIndexOf("."),
			targetOwner = separator < 0 ? currentOwner : call.substring(0, separator),
			methodName = separator < 0 ? call : call.substring(separator + 1),
			resolvedOwner = resolveOwner(targetOwner, currentOwner, classes, aliases),
			declaration = classes.get(resolvedOwner);
		if (declaration == null)
			return null;
		return staticMethodResult(resolvedOwner, methodName, currentOwner, classes, aliases, []);
	}

	static function staticMethodResult(owner:String, methodName:String, currentOwner:String, classes:Map<String, compiler.syntax.Ast.AstClass>,
			aliases:Map<String, String>, resolving:Map<String, Bool>):Null<AstType> {
		if (resolving.exists(owner))
			return null;
		resolving.set(owner, true);
		var declaration = classes.get(owner);
		if (declaration == null) {
			resolving.remove(owner);
			return null;
		}
		for (method in declaration.methods)
			if (method.isStatic && method.name == methodName && method.result != InferredType) {
				resolving.remove(owner);
				return method.result;
			}
		var base = switch declaration.base {
			case NamedType(name): name;
			case AppliedType(name, _): name;
			default: null;
		};
		if (base == null) {
			resolving.remove(owner);
			return null;
		}
		var baseOwner = resolveOwner(base, currentOwner, classes, aliases),
			result = staticMethodResult(baseOwner, methodName, currentOwner, classes, aliases, resolving);
		resolving.remove(owner);
		return result;
	}

	static function staticFieldReference(expression:AstExpression):Null<{owner:String, name:String}> {
		return switch expression {
			case Member(object, name, _):
				var owner = switch object {
					case Variable(value, _): value;
					default: null;
				};
				owner == null ? null : {owner: owner, name: name};
			case Variable(path, _):
				var separator = path.lastIndexOf(".");
				separator < 0 ? null : {owner: path.substring(0, separator), name: path.substring(separator + 1)};
			default: null;
		};
	}

	static function resolveOwner(name:String, currentOwner:String, classes:Map<String, compiler.syntax.Ast.AstClass>, aliases:Map<String, String>):String {
		if (aliases.exists(name) && classes.exists(aliases.get(name)))
			return aliases.get(name);
		if (classes.exists(name))
			return name;
		var separator = currentOwner.lastIndexOf("."),
			local = separator < 0 ? name : currentOwner.substring(0, separator + 1) + name;
		if (classes.exists(local))
			return local;
		var found:Null<String> = null;
		for (candidate in classes.keys())
			if (candidate == name || StringTools.endsWith(candidate, "." + name)) {
				if (found != null)
					return name;
				found = candidate;
			}
		return found == null ? name : found;
	}

	static function isConstantString(expression:AstExpression):Bool
		return switch expression {
			case StringLiteral(_, _): true;
			case Add(left, right, _): isConstantString(left) && isConstantString(right);
			default: false;
		};

	static function negatedType(field:AstField, value:AstExpression):AstType
		return switch value {
			case IntegerLiteral(_, _): IntType;
			case FloatLiteral(_, _): FloatType;
			default:
				throw new CompileError(new Diagnostic("E1002", 'Cannot infer type of field "${field.name}" from this initializer', field.span));
		};
}
