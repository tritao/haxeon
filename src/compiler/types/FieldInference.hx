package compiler.types;

import compiler.Ast.AstExpression;
import compiler.Ast.AstField;
import compiler.Ast.AstType;
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
			case BoolLiteral(_, _): BoolType;
			case New(typeName, _, _): NamedType(typeName);
			case NewGeneric(typeName, typeArguments, _, _): AppliedType(typeName, typeArguments);
			case NewArray(element, _, _): ArrayType(element);
			case NewMap(key, value, _): MapType(key, value);
			default:
				throw new CompileError(new Diagnostic("E1002", 'Cannot infer type of field "${field.name}" from this initializer', field.span));
		};
	}

	static function negatedType(field:AstField, value:AstExpression):AstType
		return switch value {
			case IntegerLiteral(_, _): IntType;
			case FloatLiteral(_, _): FloatType;
			default:
				throw new CompileError(new Diagnostic("E1002", 'Cannot infer type of field "${field.name}" from this initializer', field.span));
		};
}
