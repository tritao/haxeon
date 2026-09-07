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
			case New(typeName, _, _): NamedType(typeName);
			case NewGeneric(typeName, typeArguments, _, _): AppliedType(typeName, typeArguments);
			case NewArray(element, _, _): ArrayType(element);
			case NewMap(key, value, _): MapType(key, value);
			case Member(_, _, _): InferredType;
			case Variable(name, _) if (name.indexOf(".") > 0): InferredType;
			default:
				throw new CompileError(new Diagnostic("E1002", 'Cannot infer type of field "${field.name}" from this initializer', field.span));
		};
	}

	public static function resolvedType(field:AstField, owner:String, classes:Map<String, compiler.syntax.Ast.AstClass>,
			aliases:Map<String, String>):AstType {
		return resolveField(field, owner, classes, aliases, []);
	}

	static function resolveField(field:AstField, owner:String, classes:Map<String, compiler.syntax.Ast.AstClass>, aliases:Map<String, String>,
			resolving:Map<String, Bool>):AstType {
		var inferred = parsedType(field);
		if (inferred != InferredType) return inferred;
		var key = owner + "." + field.name;
		if (resolving.exists(key))
			throw new CompileError(new Diagnostic("E1002", 'Cyclic field type inference through "$key"', field.span));
		resolving.set(key, true);
		var reference = staticFieldReference(field.initializer);
		if (reference == null)
			throw new CompileError(new Diagnostic("E1002", 'Cannot infer type of field "${field.name}" from this initializer', field.span));
		var targetOwner = resolveOwner(reference.owner, owner, classes, aliases), targetClass = classes.get(targetOwner), target:Null<AstField> = null;
		if (targetClass != null)
			for (candidate in targetClass.fields)
				if (candidate.isStatic && candidate.name == reference.name) target = candidate;
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
		if (aliases.exists(name) && classes.exists(aliases.get(name))) return aliases.get(name);
		if (classes.exists(name)) return name;
		var separator = currentOwner.lastIndexOf("."), local = separator < 0 ? name : currentOwner.substring(0, separator + 1) + name;
		if (classes.exists(local)) return local;
		var found:Null<String> = null;
		for (candidate in classes.keys())
			if (candidate == name || StringTools.endsWith(candidate, "." + name)) {
				if (found != null) return name;
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
