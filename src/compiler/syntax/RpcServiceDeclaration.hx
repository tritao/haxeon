package compiler.syntax;

import compiler.core.Source.SourceSpan;
import compiler.syntax.Ast.AstInterface;

class RpcServiceDeclaration {
	public static function validate(declaration:AstInterface,
			fail:(String, SourceSpan) -> Void):Void {
		if (declaration.typeParameters.length != 0 || declaration.bases.length != 0
			|| declaration.fields.length != 0 || declaration.methods.length == 0)
			fail('RPC service "${declaration.name}" must be a nonempty, non-generic interface with only its own methods',
				declaration.span);
		for (method in declaration.methods)
			if (method.isStatic || (method.typeParameters != null && method.typeParameters.length != 0)
				|| method.arguments.length != 1 || AstPredicates.isOptionalArgument(method.arguments[0])
				|| method.arguments[0].type.match(AppliedType("haxe.Rest", _))
				|| method.result.match(VoidType))
				fail('RPC method "${declaration.name}.${method.name}" must take one required request and return one response',
					method.span);
	}
}
