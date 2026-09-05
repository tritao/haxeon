package compiler.types;

import compiler.Ast.AstExpression;
import compiler.Ast.AstField;
import compiler.Ast.AstType;
import compiler.Diagnostic;
import compiler.Diagnostic.CompileError;

/** Resolves field annotations before class signatures and bodies are typed. */
class FieldInference {
	public static function parsedType(field:AstField):AstType {
		if (field.type != null)
			return field.type;
		return switch field.initializer {
			case IntegerLiteral(_, _): IntType;
			case FloatLiteral(_, _): FloatType;
			case StringLiteral(_, _): StringType;
			case BoolLiteral(_, _): BoolType;
			case New(typeName, _, _): NamedType(typeName);
			case NewArray(element, _, _): ArrayType(element);
			case NewMap(key, value, _): MapType(key, value);
			default:
				throw new CompileError(new Diagnostic("E1002", 'Cannot infer type of field "${field.name}" from this initializer', field.span));
		};
	}
}
