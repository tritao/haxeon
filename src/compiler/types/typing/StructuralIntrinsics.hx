package compiler.types.typing;

import compiler.Source.SourceSpan;
import compiler.syntax.Ast.AstClass;
import compiler.syntax.Ast.AstExpression;
import compiler.syntax.Ast.AstField;
import compiler.syntax.Ast.AstStatement;
import compiler.syntax.Ast.AstType;
import compiler.types.Type.CompilerType;
import compiler.types.Type.NominalKind;

/**
 * `haxeon.Structural`: operations over every stored field of a class, generated from its declaration at each call site, so
 * they stay complete when a field is added. A class takes part when it is a value class or is marked `@:structural`; a
 * structural class may not extend another, whose fields would otherwise be left out.
 *
 * - `copy(value)`: a new instance (through the no-argument constructor) with every field copied, shallowly.
 * - `hash(value)`: a hash consistent with `haxeon.Equality.equals`.
 * - `changedMask(a, b)`: a bit per field, in declaration order, set where the two differ (`Equality.equals` per field).
 * - `assignChanged(target, before, after)`: copies into `target` each field that differs between `before` and `after`,
 *   leaving the others as they are, and returns the mask of the copied fields.
 * - `fieldBit(Type, "field")` and `allFieldsMask(Type)`: compile-time constants for the masks; a misspelled field is an error.
 *
 * Each expands into ordinary syntax that is then typed, like `Std.downcast`.
 */
class StructuralIntrinsics {
	static var serial = 0;

	public static function handles(name:String):Bool
		return switch name {
			case "Structural.copy", "haxeon.Structural.copy", "Structural.hash", "haxeon.Structural.hash", "Structural.changedMask",
				"haxeon.Structural.changedMask", "Structural.assignChanged", "haxeon.Structural.assignChanged", "Structural.fieldBit",
				"haxeon.Structural.fieldBit", "Structural.allFieldsMask", "haxeon.Structural.allFieldsMask": true;
			default: false;
		};

	/** The expression to type in place of the call. */
	public static function expand(session:TypingSession, name:String, arguments:Array<AstExpression>, span:SourceSpan,
			typeOf:AstExpression->CompilerType):AstExpression {
		var operation = name.substr(name.lastIndexOf(".") + 1);
		switch operation {
			case "fieldBit":
				expectArguments(name, arguments, 2, span);
				var declaration = classNamed(session, typeName(arguments[0], name, span), span),
					field = switch arguments[1] {
						case StringLiteral(value, _): value;
						default:
							fail("E1009", '$name expects the field name as a string literal', span);
							"";
					},
					fields = storedFields(declaration, span);
				for (index in 0...fields.length)
					if (fields[index].name == field)
						return IntegerLiteral(1 << index, span);
				fail("E1009", 'Class "${declaration.name}" has no stored field "$field"', span);
				return IntegerLiteral(0, span);
			case "allFieldsMask":
				expectArguments(name, arguments, 1, span);
				var count = storedFields(classNamed(session, typeName(arguments[0], name, span), span), span).length;
				return IntegerLiteral(count >= 32 ? -1 : (1 << count) - 1, span);
			case "copy":
				expectArguments(name, arguments, 1, span);
				var declaration = classOf(session, typeOf(arguments[0]), name, span);
				if (declaration.typeParameters.length > 0)
					fail("E1009", '$name does not support generic class "${declaration.name}"', span);
				var source = hold("copy-source", span), result = hold("copy-result", span);
				var statements:Array<AstStatement> = [
					VarDeclaration(source, null, arguments[0], span),
					VarDeclaration(result, null, New(declaration.name, [], span), span)
				];
				for (field in storedFields(declaration, span)) {
					if (field.isFinal)
						fail("E1009", '$name cannot copy final field "${field.name}" of "${declaration.name}"', span);
					statements.push(FieldAssignment(Variable(result, span), field.name, Member(Variable(source, span), field.name, span), span));
				}
				return BlockExpression(statements, Variable(result, span), span);
			case "changedMask":
				expectArguments(name, arguments, 2, span);
				var declaration = classOf(session, typeOf(arguments[0]), name, span),
					left = hold("left", span), right = hold("right", span), mask = hold("mask", span),
					fields = maskedFields(declaration, name, span);
				var statements:Array<AstStatement> = [
					VarDeclaration(left, null, arguments[0], span),
					VarDeclaration(right, null, arguments[1], span),
					VarDeclaration(mask, IntType, IntegerLiteral(0, span), span)
				];
				for (index in 0...fields.length)
					statements.push(If(differs(left, right, fields[index].name, span),
						[Assignment(mask, BitOr(Variable(mask, span), IntegerLiteral(1 << index, span), span), span)], [], span));
				return BlockExpression(statements, Variable(mask, span), span);
			case "assignChanged":
				expectArguments(name, arguments, 3, span);
				var declaration = classOf(session, typeOf(arguments[0]), name, span),
					target = hold("target", span), before = hold("before", span), after = hold("after", span), mask = hold("mask", span),
					fields = maskedFields(declaration, name, span);
				var statements:Array<AstStatement> = [
					VarDeclaration(target, null, arguments[0], span),
					VarDeclaration(before, null, arguments[1], span),
					VarDeclaration(after, null, arguments[2], span),
					VarDeclaration(mask, IntType, IntegerLiteral(0, span), span)
				];
				for (index in 0...fields.length) {
					var field = fields[index];
					if (field.isFinal)
						fail("E1009", '$name cannot assign final field "${field.name}" of "${declaration.name}"', span);
					statements.push(If(differs(before, after, field.name, span), [
						FieldAssignment(Variable(target, span), field.name, Member(Variable(after, span), field.name, span), span),
						Assignment(mask, BitOr(Variable(mask, span), IntegerLiteral(1 << index, span), span), span)
					], [], span));
				}
				return BlockExpression(statements, Variable(mask, span), span);
			case "hash":
				expectArguments(name, arguments, 1, span);
				var type = typeOf(arguments[0]);
				var declaration = classOf(session, type, name, span),
					value = hold("hashed", span), hash = hold("hash", span);
				var statements:Array<AstStatement> = [
					VarDeclaration(value, null, arguments[0], span),
					VarDeclaration(hash, IntType, IntegerLiteral(17, span), span)
				];
				for (field in storedFields(declaration, span)) {
					var fieldType = session.declarations.resolve(session.declarations.resolvedFieldType(declaration.name, field), field.span);
					statements.push(Assignment(hash, Call("haxeon.Structural.mix",
						[Variable(hash, span), hashOf(session, fieldType, Member(Variable(value, span), field.name, span), declaration.name + "." + field.name,
							span)], span), span));
				}
				return BlockExpression(statements, Variable(hash, span), span);
			default:
				fail("E1007", 'Unknown function "$name"', span);
				return NullLiteral(span);
		}
	}

	/** A hash of `value`, a field of type `type`, consistent with how `Equality.equals` compares it. */
	static function hashOf(session:TypingSession, type:CompilerType, value:AstExpression, where:String, span:SourceSpan):AstExpression {
		return switch type {
			case TInt: value;
			case TBool: Conditional(value, IntegerLiteral(1231, span), IntegerLiteral(1237, span), span);
			case TFloat: Call("haxeon.Structural.hashFloat", [value], span);
			case TString: Call("haxeon.Structural.hashString", [value], span);
			case TAbstract(_, _, representation):
				hashOf(session, representation, Cast(value, representationSyntax(representation, where, span), span), where, span);
			case TNullable(element):
				var held = hold("nullable", span);
				BlockExpression([VarDeclaration(held, null, value, span)],
					Conditional(Equal(Variable(held, span), NullLiteral(span), span), IntegerLiteral(0, span),
						hashOf(session, element, Variable(held, span), where, span), span), span);
			case TInstance(NominalKind.Enum, _, _):
				// Constructors only: consistent with equality, which also compares the arguments.
				Call("Type.enumIndex", [value], span);
			case TInstance(NominalKind.Class, name, _) if (isStructural(session, type)):
				var held = hold("nested", span);
				BlockExpression([VarDeclaration(held, null, value, span)],
					Conditional(Equal(Variable(held, span), NullLiteral(span), span), IntegerLiteral(0, span),
						Call("haxeon.Structural.hash", [Variable(held, span)], span), span), span);
			default:
				fail("E1025", 'Structural.hash does not support field "$where" of type "${describe(type)}"', span);
				IntegerLiteral(0, span);
		};
	}

	static function describe(type:CompilerType):String
		return switch type {
			case TInstance(_, name, _), TAbstract(name, _, _): name;
			default: compiler.semantic.SemanticSignature.type(type);
		};

	static function representationSyntax(type:CompilerType, where:String, span:SourceSpan):AstType
		return switch type {
			case TInt: IntType;
			case TFloat: FloatType;
			case TBool: BoolType;
			case TString: StringType;
			default:
				fail("E1025", 'Structural.hash does not support the abstract representation of "$where"', span);
				IntType;
		};

	/** `!Equality.equals(left.field, right.field)`. */
	static function differs(left:String, right:String, field:String, span:SourceSpan):AstExpression
		return Not(Call("haxeon.Equality.equals", [Member(Variable(left, span), field, span), Member(Variable(right, span), field, span)], span), span);

	static function maskedFields(declaration:AstClass, name:String, span:SourceSpan):Array<AstField> {
		var fields = storedFields(declaration, span);
		if (fields.length > 32)
			fail("E1009", '$name supports at most 32 fields; "${declaration.name}" has ${fields.length}', span);
		return fields;
	}

	public static function isStructural(session:TypingSession, type:CompilerType):Bool {
		if (session.relations.isValueClass(type))
			return true;
		return switch type {
			case TInstance(NominalKind.Class, name, _):
				var declaration = session.classDecls.get(name);
				declaration != null && hasStructuralMetadata(declaration);
			default: false;
		};
	}

	public static function hasStructuralMetadata(declaration:AstClass):Bool {
		for (entry in declaration.metadata)
			if (entry.name == "structural")
				return true;
		return false;
	}

	/** The instance fields with storage, in declaration order. */
	public static function storedFields(declaration:AstClass, span:SourceSpan):Array<AstField> {
		if (declaration.base != null && hasStructuralMetadata(declaration))
			fail("E1009", 'Structural class "${declaration.name}" cannot extend another class: its fields would be left out', span);
		return [for (field in declaration.fields) if (!field.isStatic && EqualityGenerator.hasStoredField(field)) field];
	}

	static function classOf(session:TypingSession, type:CompilerType, name:String, span:SourceSpan):AstClass {
		var className = switch type {
			case TInstance(NominalKind.Class, className, _) if (isStructural(session, type)): className;
			default:
				fail("E1009", '$name expects a value class or a class marked @:structural, got "${describe(type)}"', span);
				"";
		};
		return classNamed(session, className, span);
	}

	static function classNamed(session:TypingSession, name:String, span:SourceSpan):AstClass {
		var declaration = session.classDecls.get(name);
		if (declaration == null)
			fail("E1007", 'Unknown class "$name"', span);
		return declaration;
	}

	static function typeName(argument:AstExpression, name:String, span:SourceSpan):String
		return switch argument {
			case Variable(value, _): value;
			default:
				fail("E1009", '$name expects a class as its first argument', span);
				"";
		};

	static function expectArguments(name:String, arguments:Array<AstExpression>, count:Int, span:SourceSpan):Void
		if (arguments.length != count)
			fail("E1008", 'Function "$name" expects $count argument${count == 1 ? "" : "s"}, got ${arguments.length}', span);

	static function hold(purpose:String, span:SourceSpan):String
		return '$' + 'structural:$purpose:${span.start}:${serial++}';

	static function fail(code:String, message:String, span:SourceSpan):Void
		BodyTyper.fail(code, message, span);
}
