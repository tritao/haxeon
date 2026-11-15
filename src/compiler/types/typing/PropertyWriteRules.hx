package compiler.types.typing;

import compiler.core.Diagnostic;
import compiler.core.Diagnostic.CompileError;
import compiler.core.Source.SourceSpan;
import compiler.syntax.Ast;
import compiler.types.Type.CompilerType;
import compiler.types.Type.NominalKind;

/** Access to properties whose setter is `null` follows the declaring class's lexical access. */
class PropertyWriteRules {
	public static function rejectInstanceMutation(session:TypingSession, type:CompilerType, name:String,
			span:SourceSpan):Void {
		var owner = switch type {
			case TInstance(NominalKind.Class, className, _): className;
			default: null;
		};
		check(session, owner, name, false, span);
	}

	public static function rejectStaticMutation(session:TypingSession, owner:String, name:String, span:SourceSpan):Void
		check(session, owner, name, true, span);

	static function check(session:TypingSession, owner:Null<String>, name:String, isStatic:Bool, span:SourceSpan):Void {
		var remaining = 64;
		while (owner != null && remaining-- > 0) {
			var declaration = session.classDecls.get(owner);
			if (declaration == null)
				return;
			for (field in declaration.fields)
				if (field.name == name && field.isStatic == isStatic) {
					if (!canWrite(session, declaration, field))
						throw new CompileError(new Diagnostic("E1024", 'Property "$owner.$name" cannot be written here',
							span));
					return;
				}
			owner = declaration.base == null ? null : baseName(declaration.base);
		}
	}

	public static function canWrite(session:TypingSession, declaration:AstClass, field:AstField):Bool
		return field.writeAccess != NullAccess || canAccess(session, declaration, field);

	public static function canAccess(session:TypingSession, declaration:AstClass, field:AstField):Bool {
		if (session.currentContext.privateAccessDepth > 0)
			return true;
		var owner = declaration.name;
		var caller = session.currentContext.lexicalOwner;
		var current = caller, remaining = 64;
		while (current != null && remaining-- > 0) {
			if (current == owner)
				return true;
			var declaration = session.classDecls.get(current);
			current = declaration == null || declaration.base == null ? null : baseName(declaration.base);
		}
		return caller != null
			&& (grants(declaration.metadata, "allow", caller, session.currentContext.sourceFunctionName)
			|| grants(field.metadata, "allow", caller, session.currentContext.sourceFunctionName)
			|| hasAccess(session, caller, owner, field.name));
	}

	static function hasAccess(session:TypingSession, caller:String, owner:String, field:String):Bool {
		var declaration = session.classDecls.get(caller);
		if (declaration == null)
			return false;
		if (grants(declaration.metadata, "access", owner, owner + "." + field))
			return true;
		for (method in declaration.methods) {
			var name = method.name.indexOf(".") >= 0 ? method.name : caller + "." + method.name;
			if (name == session.currentContext.sourceFunctionName
				&& method.metadata != null
				&& grants(method.metadata, "access", owner, owner + "." + field))
				return true;
		}
		return false;
	}

	static function grants(metadata:Array<AstMetadata>, kind:String, caller:String, functionName:String):Bool {
		for (entry in metadata)
			if (entry.name == kind)
				for (argument in entry.arguments) {
					var path = expressionPath(argument);
					if (path != null
						&& (caller == path || functionName == path || StringTools.startsWith(caller, path + ".")))
						return true;
				}
		return false;
	}

	static function expressionPath(expression:AstExpression):Null<String>
		return switch expression {
			case Variable(name, _): name;
			case Member(object, name, _):
				var prefix = expressionPath(object);
				prefix == null ? null : prefix + "." + name;
			default: null;
		};

	static function baseName(type:AstType):Null<String>
		return switch type {
			case NamedType(name), AppliedType(name, _): name;
			default: null;
		};
}
