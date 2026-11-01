package compiler.types.typing;

import compiler.Source.SourceSpan;
import compiler.syntax.Ast.AstClass;
import compiler.syntax.Ast.AstExpression;
import compiler.syntax.Ast.AstField;
import compiler.syntax.Ast.AstStatement;
import compiler.types.Type.CompilerType;
import compiler.types.Type.NominalKind;

/** Compiler expansion for Diffable field masks and class copies. */
class DiffIntrinsics {
	static var serial = 0;

	public static function handles(name:String):Bool
		return switch name {
			case "Diff.copy", "haxeon.Diff.copy", "Diff.mask", "haxeon.Diff.mask", "Diff.apply", "haxeon.Diff.apply", "Diff.bit",
				"haxeon.Diff.bit", "Diff.all", "haxeon.Diff.all": true;
			default: false;
		};

	public static function expand(session:TypingSession, name:String, arguments:Array<AstExpression>, span:SourceSpan,
			typeOf:AstExpression->CompilerType):AstExpression {
		var operation = name.substr(name.lastIndexOf(".") + 1);
		switch operation {
			case "bit":
				expectArguments(name, arguments, 2, span);
				var declaration = classNamed(session, typeName(arguments[0], name, span), span),
					field = switch arguments[1] {
						case StringLiteral(value, _): value;
						default:
							fail("E1009", '$name expects the field name as a string literal', span);
							"";
					};
				requireDiffable(session, declaration, name, span);
				var fields = maskedFields(declaration, name, span);
				for (index in 0...fields.length)
					if (fields[index].name == field)
						return IntegerLiteral(1 << index, span);
				fail("E1009", 'Type "${declaration.name}" has no stored field "$field"', span);
				return null;
			case "all":
				expectArguments(name, arguments, 1, span);
				var declaration = classNamed(session, typeName(arguments[0], name, span), span);
				requireDiffable(session, declaration, name, span);
				var count = maskedFields(declaration, name, span).length;
				return IntegerLiteral(count >= 32 ? -1 : (1 << count) - 1, span);
			case "copy":
				expectArguments(name, arguments, 1, span);
				var type = typeOf(arguments[0]), declaration = classOf(session, type, name, span);
				if (session.relations.isStruct(type))
					fail("E1009", '$name is unnecessary for struct "${declaration.name}"; bind the value to a local to copy it', span);
				if (declaration.typeParameters.length > 0)
					fail("E1009", '$name does not support generic class "${compiler.semantic.SemanticSignature.display(type)}"', span);
				var source = hold("copy-source", span), result = hold("copy-result", span),
					statements:Array<AstStatement> = [
						VarDeclaration(source, null, arguments[0], span),
						VarDeclaration(result, null, New(declaration.name, [], span), span)
					];
				for (field in storedFields(declaration)) {
					if (!isWritable(field))
						fail("E1009", '$name cannot copy immutable field "${field.name}" of "${compiler.semantic.SemanticSignature.display(type)}"', span);
					statements.push(FieldAssignment(Variable(result, span), field.name, Member(Variable(source, span), field.name, span), span));
				}
				return BlockExpression(statements, Variable(result, span), span);
			case "mask":
				expectArguments(name, arguments, 2, span);
				var declaration = classOf(session, typeOf(arguments[0]), name, span),
					left = hold("left", span), right = hold("right", span), mask = hold("mask", span),
					fields = maskedFields(declaration, name, span),
					statements:Array<AstStatement> = [
						VarDeclaration(left, null, arguments[0], span),
						VarDeclaration(right, null, arguments[1], span),
						VarDeclaration(mask, IntType, IntegerLiteral(0, span), span)
					];
				for (index in 0...fields.length)
					statements.push(If(differs(left, right, fields[index].name, span),
						[Assignment(mask, BitOr(Variable(mask, span), IntegerLiteral(1 << index, span), span), span)], [], span));
				return BlockExpression(statements, Variable(mask, span), span);
			case "apply":
				expectArguments(name, arguments, 3, span);
				var declaration = classOf(session, typeOf(arguments[0]), name, span),
					target = hold("target", span), before = hold("before", span), after = hold("after", span), mask = hold("mask", span),
					fields = maskedFields(declaration, name, span),
					statements:Array<AstStatement> = [
						VarDeclaration(target, null, Call("$value.place", [arguments[0]], span), span),
						VarDeclaration(before, null, arguments[1], span),
						VarDeclaration(after, null, arguments[2], span),
						VarDeclaration(mask, IntType, IntegerLiteral(0, span), span)
					];
				for (index in 0...fields.length) {
					var field = fields[index];
					if (!isWritable(field))
						fail("E1009", '$name cannot assign immutable field "${field.name}" of "${declaration.name}"', span);
					statements.push(If(differs(before, after, field.name, span), [
						FieldAssignment(Variable(target, span), field.name, Member(Variable(after, span), field.name, span), span),
						Assignment(mask, BitOr(Variable(mask, span), IntegerLiteral(1 << index, span), span), span)
					], [], span));
				}
				return BlockExpression(statements, Variable(mask, span), span);
			default:
				fail("E1007", 'Unknown function "$name"', span);
				return null;
		}
	}

	public static function storedFields(declaration:AstClass):Array<AstField>
		return [for (field in declaration.fields) if (!field.isStatic && hasStoredField(field)) field];

	public static function hasStoredField(field:AstField):Bool {
		if (hasDirectAccess(field.readAccess) || hasDirectAccess(field.writeAccess))
			return true;
		for (metadata in field.metadata)
			if (metadata.name == "isVar")
				return true;
		return false;
	}

	static function hasDirectAccess(access:Null<compiler.syntax.Ast.AstFieldAccess>):Bool
		return switch access {
			case GetAccess, SetAccess, NeverAccess: false;
			default: true;
		};

	public static function isWritable(field:AstField):Bool {
		if (field.isFinal)
			return false;
		return switch field.writeAccess {
			case GetAccess, NeverAccess: false;
			default: true;
		};
	}

	static function maskedFields(declaration:AstClass, name:String, span:SourceSpan):Array<AstField> {
		var fields = storedFields(declaration);
		if (fields.length > 32)
			fail("E1009", '$name supports at most 32 fields; "${declaration.name}" has ${fields.length}', span);
		return fields;
	}

	static function classOf(session:TypingSession, type:CompilerType, name:String, span:SourceSpan):AstClass {
		var className = switch type {
			case TInstance(NominalKind.Class, className, _) if (DeclaredConformance.has(session, type, "Diffable")): className;
			default:
				fail("E1009", '$name requires Diffable conformance for "${compiler.semantic.SemanticSignature.display(type)}"', span);
				"";
		};
		return classNamed(session, className, span);
	}

	static function requireDiffable(session:TypingSession, declaration:AstClass, name:String, span:SourceSpan):Void {
		var type = TInstance(NominalKind.Class, declaration.name, []);
		if (!DeclaredConformance.has(session, type, "Diffable"))
			fail("E1009", '$name requires Diffable conformance for "${declaration.name}"', span);
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

	static function differs(left:String, right:String, field:String, span:SourceSpan):AstExpression
		return NotEqual(Member(Variable(left, span), field, span), Member(Variable(right, span), field, span), span);

	static function hold(purpose:String, span:SourceSpan):String
		return '$' + 'diff:$purpose:${span.start}:${serial++}';

	static function fail(code:String, message:String, span:SourceSpan):Void
		BodyTyper.fail(code, message, span);
}
