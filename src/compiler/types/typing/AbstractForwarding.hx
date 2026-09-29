package compiler.types.typing;

import compiler.syntax.Ast.AstAbstract;
import compiler.syntax.Ast.AstExpression;
import compiler.types.Type.CompilerType;

/** Read-only forwarding declared on an abstract, without implicit conversion to its storage type. */
class AbstractForwarding {
	public static function arrayStorage(session:TypingSession, type:CompilerType, member:Null<String>):Null<CompilerType> {
		return switch type {
			case TAbstract(name, _, underlying):
				var declaration = session.declarations.abstracts.get(name);
				if (declaration == null || !allowed(declaration, member)) null; else switch underlying {
					case TArray(_): underlying;
					default: null;
				}
			default: null;
		};
	}

	static function allowed(declaration:AstAbstract, member:Null<String>):Bool {
		if (declaration.metadata == null)
			return false;
		for (entry in declaration.metadata) {
			if (member == null && entry.name == "arrayAccess")
				return true;
			if (member != null && entry.name == "forward")
				for (argument in entry.arguments)
					switch argument {
						case AstExpression.Variable(name, _) if (name == member):
							return true;
						default:
					}
		}
		return false;
	}
}
