package compiler.types.typing;

import compiler.core.Source.SourceSpan;
import compiler.syntax.Ast.AstArgument;
import compiler.syntax.Ast.AstExpression;
import compiler.syntax.Ast.AstStatement;
import compiler.syntax.Ast.AstType;
import compiler.syntax.Ast.TemporaryLocal;
import compiler.syntax.RpcServiceDeclaration;
import compiler.types.TypedAst.TypedExpression;
import compiler.types.TypedAst.TypedStatement;
import compiler.types.analysis.Scope;

/** Lowers service calls to typed descriptors and ordinary closure-backed stub fields. */
@:access(compiler.types.typing.BodyTyper)
class RpcServiceTyping {
	public static inline final CONNECTION = "haxeon.rpc.RpcConnection";
	public static inline final METHOD = "haxeon.rpc.RpcMethod";

	public static function typeCall(session:TypingSession, body:BodyTyping, receiver:TypedExpression, methodKey:String,
			operation:String,
			arguments:Array<AstExpression>, span:SourceSpan, scope:Scope):TypedExpression {
		var serving = operation == "serve";
		if (serving ? arguments.length != 2 : arguments.length < 1 || arguments.length > 2)
			BodyTyper.fail("E1008", serving ? "RpcConnection.serve expects an interface and its implementation"
				: "RpcConnection.of expects an interface and an optional timeout", span);
		var owner = switch arguments[0] {
			case Variable(name, _) if (session.interfaceDecls.exists(name)): name;
			default:
				BodyTyper.fail("E1009", 'RpcConnection.$operation expects a service interface', span);
				null;
		};
		var service = session.interfaceDecls.required(owner);
		RpcServiceDeclaration.validate(service, (message, at) -> BodyTyper.fail("E1024", message, at));

		var ids:Map<Int, Bool> = [], pinned:Null<Bool> = null;
		var methodIds = [for (method in service.methods) {
			var name = owner + "." + method.name,
				id = WireCodecGenerator.memberId(method.metadata ?? [], name, method.span);
			if (pinned != null && pinned != (id != 0))
				BodyTyper.fail("E1024", 'RPC service "$owner" mixes named and numbered methods', method.span);
			pinned = id != 0;
			if (id != 0) {
				if (ids.exists(id))
					BodyTyper.fail("E1024", 'RPC service "$owner" uses duplicate @:id($id)', method.span);
				ids.set(id, true);
			}
			id;
		}];

		var connection = new TemporaryLocal("$rpc:connection"),
			inner = new Scope(scope),
			binding = inner.define(connection.name, receiver.type, span, true, null, false, null, null, connection);
		body.bindCell(binding, receiver.type);
		var connectionValue = TemporaryVariable(connection, span),
			argument = new TemporaryLocal(serving ? "$rpc:implementation" : "$rpc:timeout"),
			argumentValue = TemporaryVariable(argument, span),
			bindings:Array<AstStatement> = [
				TemporaryDeclaration(argument, serving ? NamedType(owner) : IntType,
					arguments.length == 2 ? arguments[1] : IntegerLiteral(1000, span), span)
			],
			fields:Array<compiler.syntax.Ast.AstObjectField> = [],
			routes:Array<AstExpression> = [];
		for (index in 0...service.methods.length) {
			var method = service.methods[index],
				name = owner + "." + method.name,
				at = SourceSpan.generatedIn(span.file, span.start, span.end, "rpc:" + name),
				requestType = method.arguments[0].type,
				responseType = method.result,
				descriptor = new TemporaryLocal("$rpc:method:" + method.name);
			bindings.push(TemporaryDeclaration(descriptor, AppliedType(METHOD, [requestType, responseType]),
				Call("$rpc.method", [IntegerLiteral(methodIds[index], at), StringLiteral(name, at)], at), at));
			var descriptorValue = TemporaryVariable(descriptor, at),
				request = new TemporaryLocal("$rpc:request"),
				requestValue = TemporaryVariable(request, at),
				identity = 'rpc:$name@${span.start}:${span.end}';
			if (serving) {
				var context = new TemporaryLocal("$rpc:context"),
					response = MethodCall(argumentValue, method.name, [requestValue], at),
					respond = MethodCall(TemporaryVariable(context, at), "respond", [response], at),
					handler = Lambda([
						parameter(request, requestType, at),
						parameter(context, AppliedType("haxeon.rpc.RpcContext", [responseType]), at)
					],
						[Expression(respond, at)], identity, at);
				routes.push(AnnotatedExpression(PrivateAccess,
					MethodCall(descriptorValue, "route", [handler, Member(connectionValue, "finish", at)], at), at));
			} else {
				var answer = new TemporaryLocal("$rpc:answer"),
					error = new TemporaryLocal("$rpc:error"),
					call = MethodCall(connectionValue, "call", [
						descriptorValue,
						requestValue,
						argumentValue,
						TemporaryVariable(answer, at),
						TemporaryVariable(error, at)
					], at),
					stub = Lambda([
						parameter(request, requestType, at),
						parameter(answer, FunctionType([responseType], VoidType, []), at),
						parameter(error, FunctionType([NamedType("haxeon.rpc.RpcError")], VoidType, []), at)
					], [Return(call, at)], identity, at);
				fields.push({name: method.name, value: stub, span: at});
			}
		}

		var result = serving ? AnnotatedExpression(PrivateAccess,
			MethodCall(connectionValue, "installRoutes", [ArrayLiteral(routes, span)], span), span)
			: ObjectLiteral(fields, span),
			typed = body.typeExpression(BlockExpression(bindings, result, span), inner);
		session.invalidateUnknownCall(scope);
		return new TypedExpression(TBlockExpression([TVar(binding.id, receiver, span)], typed), typed.type, span, false,
			null, null, methodKey);
	}

	static function parameter(local:TemporaryLocal, type:AstType, span:SourceSpan):AstArgument
		return {name: local.name, type: type, span: span, local: local};
}
