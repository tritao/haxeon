package compiler.types.typing;

import compiler.core.Diagnostic;
import compiler.core.DiagnosticCode;
import compiler.core.UnresolvedNameKind;
import compiler.core.Diagnostic.CompileError;
import compiler.core.InternalError;
import compiler.core.Source.SourceSpan;
import compiler.syntax.Ast.AstClass;
import compiler.syntax.Ast.AstExpression;
import compiler.syntax.Ast.AstField;
import compiler.syntax.Ast.AstFunction;
import compiler.syntax.Ast.AstStatement;
import compiler.syntax.Ast.TemporaryLocal;
import compiler.types.Type.CompilerType;
import compiler.types.Type.NominalKind;
import compiler.types.typing.KeyPathTyping.KeyPathField;

/** A stored field and its semantic type in the instantiation that declared it. */
typedef ConformanceField = {
	final declaration:AstClass;
	final field:AstField;
	final type:CompilerType;
}
typedef ConformanceMethod = {
	final declaration:AstClass;
	final method:AstFunction;
	final type:CompilerType;
}

/** Compiler expansion for Diffable field masks, class copies, and snapshot fingerprints. */
class DiffIntrinsics {

	public static function handles(name:String):Bool
		return switch name {
			case "Diff.copy", "haxeon.Diff.copy", "Diff.mask", "haxeon.Diff.mask", "Diff.apply", "haxeon.Diff.apply",
				"Diff.bit",
				"haxeon.Diff.bit", "Diff.all", "haxeon.Diff.all", "Diff.fingerprint", "haxeon.Diff.fingerprint": true;
			default: false;
		};

	public static function expand(session:TypingSession, name:String, arguments:Array<AstExpression>, span:SourceSpan,
			typeOf:AstExpression->CompilerType,
			pathOf:AstExpression->compiler.types.TypedAst.TypedExpression):AstExpression {
		var operation = name.substr(name.lastIndexOf(".") + 1);
		switch operation {
			case "fingerprint":
				expectArguments(name, arguments, 1, span);
				var type = typeOf(arguments[0]),
					declaration = classOf(session, type, name, span),
					value = hold(session, "fingerprint-value", span),
					hash = hold(session, "fingerprint-hash", span),
					statements:Array<AstStatement> = [
						TemporaryDeclaration(value, null, arguments[0], span),
						TemporaryDeclaration(hash, IntType, IntegerLiteral(17, span), span)
					];
				maskedFields(session, declaration, name, span);
				for (entry in conformanceFields(session, type)) {
					var field = entry.field, fieldType = entry.type;
					if (!DeclaredConformance.supportsHash(session, fieldType))
						fail(DiagnosticCode.CONFORMANCE,
							'Cannot synthesize Diff.fingerprint for "${compiler.semantic.SemanticSignature.display(type)}": field "${field.name}" does not conform to Hashable',
							field.span);
					var fieldValue = synthesized(Member(TemporaryVariable(value, span), field.name, span), span),
						fieldHash = Call("haxeon.Hashing.hash", [fieldValue], span),
						mixed = Add(Mul(TemporaryVariable(hash, span), IntegerLiteral(31, span), span), fieldHash,
							span);
					statements.push(TemporaryAssignment(hash, mixed, span));
				}
				return BlockExpression(statements, TemporaryVariable(hash, span), span);
			case "bit":
				expectArguments(name, arguments, 1, span);
				var path:Null<{
					final root:CompilerType;
					final fields:Array<KeyPathField>;
				}> = switch arguments[0] {
					case KeyPathLiteral(root, fields, fieldSpan):
						var resolved = KeyPathTyping.diffField(session, root, fields, fieldSpan);
						{
							root:resolved.root, fields:resolved.fields
						};
					case _:
						var resolved = KeyPathTyping.known(session, pathOf(arguments[0]));
						resolved == null ? null : {root: resolved.root, fields: resolved.fields};
				};
				if (path == null || path.fields.length != 1)
					fail(DiagnosticCode.VALUE_CONVERSION, '$name requires a known direct-field key path', span);
				var declaration = classOf(session, path.root, name, span), field = path.fields[0].field.name;
				requireDiffable(session, declaration, name, span);
				var fields = maskedFields(session, declaration, name, span);
				for (index in 0...fields.length)
					if (fields[index].name == field) return IntegerLiteral(1 << index, span);
				throw new InternalError("Resolved key path field is absent from Diffable layout");
			case "all":
				expectArguments(name, arguments, 1, span);
				var declaration = classNamed(session, typeName(arguments[0], name, span), span);
				requireDiffable(session, declaration, name, span);
				var count = maskedFields(session, declaration, name, span).length;
				return IntegerLiteral(count >= 32 ? -1 : (1 << count) - 1, span);
			case "copy":
				expectArguments(name, arguments, 1, span);
				var type = typeOf(arguments[0]), declaration = classOf(session, type, name, span);
				if (session.relations.isStruct(type))
					fail(DiagnosticCode.VALUE_CONVERSION,
						'$name is unnecessary for struct "${declaration.name}"; bind the value to a local to copy it',
						span);
				if (declaration.typeParameters.length > 0)
					fail(DiagnosticCode.VALUE_CONVERSION,
						'$name does not support generic class "${compiler.semantic.SemanticSignature.display(type)}"',
						span);
				var source = hold(session, "copy-source", span),
					result = hold(session, "copy-result", span),
					statements:Array<AstStatement> = [
						TemporaryDeclaration(source, null, arguments[0], span),
						TemporaryDeclaration(result, null, synthesized(New(declaration.name, [], span), span), span)
					];
				for (entry in conformanceFields(session, type)) {
					var field = entry.field;
					if (!isWritable(field))
						fail(DiagnosticCode.VALUE_CONVERSION,
							'$name cannot copy immutable field "${field.name}" of "${compiler.semantic.SemanticSignature.display(type)}"',
							span);
					statements.push(synthesizedStatement(FieldAssignment(TemporaryVariable(result, span), field.name,
						Member(TemporaryVariable(source, span), field.name, span), span), span));
				}
				return BlockExpression(statements, TemporaryVariable(result, span), span);
			case "mask":
				expectArguments(name, arguments, 2, span);
				var declaration = classOf(session, typeOf(arguments[0]), name, span),
					left = hold(session, "left", span),
					right = hold(session, "right", span),
					mask = hold(session, "mask", span),
					fields = maskedFields(session, declaration, name, span),
					statements:Array<AstStatement> = [
						TemporaryDeclaration(left, null, arguments[0], span),
						TemporaryDeclaration(right, null, arguments[1], span),
						TemporaryDeclaration(mask, IntType, IntegerLiteral(0, span), span)
					];
				for (index in 0...fields.length)
					statements.push(If(differs(left, right, fields[index].name, span),
						[TemporaryAssignment(mask,
						BitOr(TemporaryVariable(mask, span), IntegerLiteral(1 << index, span), span), span)],
						[], span));
				return BlockExpression(statements, TemporaryVariable(mask, span), span);
			case "apply":
				expectArguments(name, arguments, 3, span);
				var declaration = classOf(session, typeOf(arguments[0]), name, span),
					target = hold(session, "target", span),
					before = hold(session, "before", span),
					after = hold(session, "after", span),
					mask = hold(session, "mask", span),
					fields = maskedFields(session, declaration, name, span),
					statements:Array<AstStatement> = [
						TemporaryDeclaration(target, null, Call("$value.place", [arguments[0]], span), span),
						TemporaryDeclaration(before, null, arguments[1], span),
						TemporaryDeclaration(after, null, arguments[2], span),
						TemporaryDeclaration(mask, IntType, IntegerLiteral(0, span), span)
					];
				for (index in 0...fields.length) {
					var field = fields[index];
					if (!isWritable(field))
						fail(DiagnosticCode.VALUE_CONVERSION,
							'$name cannot assign immutable field "${field.name}" of "${declaration.name}"',
							span);
					statements.push(If(differs(before, after, field.name, span), [
						synthesizedStatement(FieldAssignment(TemporaryVariable(target, span), field.name,
							Member(TemporaryVariable(after, span), field.name, span), span), span),
						TemporaryAssignment(mask,
							BitOr(TemporaryVariable(mask, span), IntegerLiteral(1 << index, span), span), span)
					], [], span));
				}
				return BlockExpression(statements, TemporaryVariable(mask, span), span);
			default:
				throw new CompileError(Diagnostic.unresolved(DiagnosticCode.DECLARATION_OR_MODIFIER,
					UnresolvedNameKind.WantedFunction, name, span));
		}
	}

	public static function storedFields(declaration:AstClass):Array<AstField>
		return [for (field in declaration.fields) if (!field.isStatic && hasStoredField(field)) field];

	/** Walk base fields first and substitute type arguments at each inheritance step. */
	public static function conformanceFields(session:TypingSession, type:CompilerType):Array<ConformanceField> {
		var result:Array<ConformanceField> = [];
		function collect(current:CompilerType):Void {
			switch current {
				case TInstance(NominalKind.Class, name, arguments):
					var declaration = session.classDecls.get(name);
					if (declaration == null) throw new InternalError('Missing value type declaration "$name"');
					var substitutions:Map<String, CompilerType> = [];
					for (index in 0...declaration.typeParameters.length) {
						var parameter = declaration.typeParameters[index],
							argument = index < arguments.length ? arguments[index] : TTypeParameter(name, parameter);
						substitutions.set(parameter, argument);
						substitutions.set(name + "." + parameter, argument);
					}
					if (declaration.base != null)
						collect(session.declarations.resolve(declaration.base, declaration.span, substitutions));
					for (field in storedFields(declaration))
						result.push({
							declaration: declaration,
							field: field,
							type: session.declarations.types.fieldType(name, field, substitutions)
						});
				default: throw new InternalError('Expected a class in value conformance traversal: $current');
			}
		}
		collect(type);
		return result;
	}

	/** Resolve the closest handwritten conformance method with its instantiated owner type. */
	public static function conformanceMethod(session:TypingSession, type:CompilerType,
			methodName:String):Null<ConformanceMethod> {
		return switch type {
			case TInstance(NominalKind.Class, name, arguments):
				var declaration = session.classDecls.get(name);
				if (declaration == null) throw new InternalError('Missing value type declaration "$name"');
				var found:Null<AstFunction> = null;
				for (method in declaration.methods) if (method.name == methodName) {
					found = method;
					break;
				}
				if (found != null) {
					declaration:declaration, method:found, type:type
				};
				else if (declaration.base == null) null;
				else {
					var substitutions:Map<String, CompilerType> = [];
					for (index in 0...declaration.typeParameters.length) {
						var parameter = declaration.typeParameters[index],
							argument = index < arguments.length ? arguments[index] : TTypeParameter(name, parameter);
						substitutions.set(parameter, argument);
						substitutions.set(name + "." + parameter, argument);
					}
					conformanceMethod(session,
						session.declarations.resolve(declaration.base, declaration.span, substitutions), methodName);
				}
			default: null;
		};
	}

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

	static function maskedFields(session:TypingSession, declaration:AstClass, name:String,
			span:SourceSpan):Array<AstField> {
		var type = TInstance(NominalKind.Class, declaration.name,
			[for (parameter in declaration.typeParameters) TTypeParameter(declaration.name, parameter)]),
			fields = [for (entry in conformanceFields(session, type)) entry.field];
		if (fields.length > 32)
			fail(DiagnosticCode.VALUE_CONVERSION,
				'$name supports at most 32 fields; "${declaration.name}" has ${fields.length}', span);
		return fields;
	}

	static function classOf(session:TypingSession, type:CompilerType, name:String, span:SourceSpan):AstClass {
		var className = switch type {
			case TInstance(NominalKind.Class, className,
				_) if (DeclaredConformance.has(session, type, "Diffable")): className;
			default:
				fail(DiagnosticCode.VALUE_CONVERSION,
					'$name requires Diffable conformance for "${compiler.semantic.SemanticSignature.display(type)}"',
					span);
				"";
		};
		return classNamed(session, className, span);
	}

	static function requireDiffable(session:TypingSession, declaration:AstClass, name:String, span:SourceSpan):Void {
		var type = TInstance(NominalKind.Class, declaration.name, []);
		if (!DeclaredConformance.has(session, type, "Diffable"))
			fail(DiagnosticCode.VALUE_CONVERSION, '$name requires Diffable conformance for "${declaration.name}"',
				span);
	}

	static function classNamed(session:TypingSession, name:String, span:SourceSpan):AstClass {
		var declaration = session.classDecls.get(name);
		if (declaration == null)
			throw new CompileError(Diagnostic.unresolved(DiagnosticCode.DECLARATION_OR_MODIFIER,
				UnresolvedNameKind.WantedClass, name, span));
		return declaration;
	}

	static function typeName(argument:AstExpression, name:String, span:SourceSpan):String
		return switch argument {
			case Variable(value, _): value;
			default:
				fail(DiagnosticCode.VALUE_CONVERSION, '$name expects a class as its first argument', span);
				"";
		};

	static function expectArguments(name:String, arguments:Array<AstExpression>, count:Int, span:SourceSpan):Void
		if (arguments.length != count)
			fail(DiagnosticCode.CALL_FORM,
				'Function "$name" expects $count argument${count == 1 ? "" : "s"}, got ${arguments.length}',
				span);

	static function differs(left:TemporaryLocal, right:TemporaryLocal, field:String, span:SourceSpan):AstExpression
		return synthesized(NotEqual(Member(TemporaryVariable(left, span), field, span),
			Member(TemporaryVariable(right, span), field, span), span),
			span);

	/** A temporary, named by its place and its ordinal in the function being typed, so the same source gives the same name in any session. */
	static function hold(session:TypingSession, purpose:String, span:SourceSpan):TemporaryLocal
		return new TemporaryLocal('$' + 'diff:$purpose:${span.start}:${session.currentContext.diffTemporary++}');

	@:noReturn
	static function fail(code:DiagnosticCode, message:String, span:SourceSpan):Void
		BodyTyper.fail(code, message, span);

	/**
	 * An access this expansion makes to a member of the value's own class, which may be private: the conformance reads and writes
	 * every stored field, as the class's own code would (`MemberAccess`). The caller's arguments are bound to locals before, so they
	 * keep the caller's access.
	 */
	static function synthesized(expression:AstExpression, span:SourceSpan):AstExpression
		return AnnotatedExpression(PrivateAccess, expression, span);

	static function synthesizedStatement(statement:AstStatement, span:SourceSpan):AstStatement
		return AnnotatedStatement(PrivateAccess, statement, span);

}
