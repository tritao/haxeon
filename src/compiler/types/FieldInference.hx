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
			case Negate(value, _): negatedType(field, value);
			case StringLiteral(_, _): StringType;
			case Add(left, right, _) if (isConstantString(left) && isConstantString(right)): StringType;
			case BoolLiteral(_, _): BoolType;
			case Add(_, _, _), Sub(_, _, _), Mul(_, _, _), Div(_, _, _), Mod(_, _, _), BitAnd(_, _, _), BitXor(_, _, _), BitOr(_, _, _), ShiftLeft(_, _, _),
				ShiftRight(_, _, _), UnsignedShiftRight(_, _, _): constantNumericType(field, initializer);
			case New(typeName, _, _): NamedType(typeName);
			case NewGeneric(typeName, typeArguments, _, _): AppliedType(typeName, typeArguments);
			case NewArray(element, _, _): ArrayType(element);
			case ArrayLiteral(values, _): arrayLiteralType(field, values);
			case NewMap(key, value, _): MapType(key, value);
			case Member(_, _, _): InferredType;
			case Variable(name, _) if (name.indexOf(".") > 0): InferredType;
			default:
				throw new CompileError(new Diagnostic("E1002", 'Cannot infer type of field "${field.name}" from this initializer', field.span));
		};
	}

	static function arrayLiteralType(field:AstField, values:Array<AstExpression>):AstType {
		if (values.length == 0)
			throw new CompileError(new Diagnostic("E1002", 'Cannot infer type of empty array field "${field.name}"', field.span));
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
		if (inferred == null)
			throw new CompileError(new Diagnostic("E1002", 'Cannot infer type of field "${field.name}" from this initializer', field.span));
		return inferred;
	}

	static function nullableNumericType(expression:AstExpression):Null<AstType>
		return switch expression {
			case IntegerLiteral(_, _): IntType;
			case FloatLiteral(_, _): FloatType;
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

	public static function resolvedType(field:AstField, owner:String, classes:Map<String, compiler.syntax.Ast.AstClass>, aliases:Map<String, String>):AstType {
		return resolveField(field, owner, classes, aliases, []);
	}

	static function resolveField(field:AstField, owner:String, classes:Map<String, compiler.syntax.Ast.AstClass>, aliases:Map<String, String>,
			resolving:Map<String, Bool>):AstType {
		var inferred = parsedType(field);
		if (inferred != InferredType)
			return inferred;
		var key = owner + "." + field.name;
		if (resolving.exists(key))
			throw new CompileError(new Diagnostic("E1002", 'Cyclic field type inference through "$key"', field.span));
		resolving.set(key, true);
		var reference = staticFieldReference(field.initializer);
		if (reference == null)
			throw new CompileError(new Diagnostic("E1002", 'Cannot infer type of field "${field.name}" from this initializer', field.span));
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
		var result = resolveField(target, targetOwner, classes, aliases, resolving);
		resolving.remove(key);
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
