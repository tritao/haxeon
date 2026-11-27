package compiler.types.typing;

import compiler.core.DiagnosticCode;
import compiler.core.Source.SourceSpan;
import compiler.core.StdlibNames;
import compiler.semantic.ImplicitConstructors;
import compiler.syntax.Ast.AstArgument;
import compiler.syntax.Ast.AstExpression;
import compiler.syntax.Ast.AstStatement;
import compiler.syntax.Ast.AstType;
import compiler.syntax.Ast.TemporaryLocal;
import compiler.syntax.RpcServiceDeclaration;
import compiler.types.Type.CompilerType;
import compiler.types.Type.NominalKind;
import compiler.types.TypedAst.TypedExpression;
import compiler.types.TypedAst.TypedStatement;
import compiler.types.analysis.Scope;

/** Lowers service calls to typed descriptors and ordinary closure-backed stub fields. */
@:access(compiler.types.typing.BodyTyper)
class RpcServiceTyping {
	public static function typeCall(session:TypingSession, body:BodyTyping, receiver:TypedExpression, methodKey:String,
			operation:String, serviceType:Null<CompilerType>, arguments:Array<AstExpression>, span:SourceSpan,
			scope:Scope):TypedExpression {
		var serving = operation == "serve";
		var owner = switch serviceType {
			case TInstance(NominalKind.Interface, name, []): name;
			case null:
				BodyTyper.fail(DiagnosticCode.CALL_FORM,
					'RpcConnection.$operation takes the service interface as a type argument: $operation<Service>(...)',
					span);
				null;
			default:
				BodyTyper.fail(DiagnosticCode.VALUE_CONVERSION,
					'RpcConnection.$operation expects a service interface, got ${compiler.semantic.SemanticSignature.display(serviceType)}',
					span);
				null;
		};
		if (serving ? arguments.length != 1 : arguments.length > 1)
			BodyTyper.fail(DiagnosticCode.CALL_FORM,
				serving ? "RpcConnection.serve expects the service's implementation"
				: "RpcConnection.of expects an optional timeout", span);
		var service = session.interfaceDecls.required(owner);
		RpcServiceDeclaration.validate(service,
			(message, at) -> BodyTyper.fail(DiagnosticCode.ANNOTATION_OR_SCHEMA, message, at));

		var ids:Map<Int, Bool> = [], pinned:Null<Bool> = null;
		var methodIds = [for (method in service.methods) {
			var name = owner + "." + method.name,
				id = WireCodecGenerator.memberId(method.metadata ?? [], name, method.span);
			if (pinned != null && pinned != (id != 0))
				BodyTyper.fail(DiagnosticCode.ANNOTATION_OR_SCHEMA,
					'RPC service "$owner" mixes named and numbered methods', method.span);
			pinned = id != 0;
			if (id != 0) {
				if (ids.exists(id))
					BodyTyper.fail(DiagnosticCode.ANNOTATION_OR_SCHEMA, 'RPC service "$owner" uses duplicate @:id($id)',
						method.span);
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
					arguments.length == 1 ? arguments[0] : IntegerLiteral(1000, span), span)
			],
			fields:Array<compiler.syntax.Ast.AstObjectField> = [],
			routes:Array<AstExpression> = [];
		for (index in 0...service.methods.length) {
			var method = service.methods[index],
				name = owner + "." + method.name,
				at = SourceSpan.generatedIn(span.file, span.start, span.end, "rpc:" + name),
				requestType = method.arguments[0].type,
				asyncResponse = futurePayload(session, method.result),
				responseType = asyncResponse ?? method.result,
				descriptor = new TemporaryLocal("$rpc:method:" + method.name);
			bindings.push(TemporaryDeclaration(descriptor, AppliedType(StdlibNames.RPC_METHOD, [
				requestType,
				responseType
			]),
				Call("$rpc.method", [IntegerLiteral(methodIds[index], at), StringLiteral(name, at)], at), at));
			var descriptorValue = TemporaryVariable(descriptor, at),
				request = new TemporaryLocal("$rpc:request"),
				requestValue = TemporaryVariable(request, at),
				identity = 'rpc:$name@${span.start}:${span.end}';
			if (serving) {
				var context = new TemporaryLocal("$rpc:context"),
					response = MethodCall(argumentValue, method.name, [requestValue], at),
					respond = MethodCall(TemporaryVariable(context, at),
						asyncResponse == null ? "respond" : "respondFuture", [response], at),
					handler = Lambda([
						parameter(request, requestType, at),
						parameter(context, AppliedType(StdlibNames.RPC_CONTEXT, [responseType]), at)
					],
						[Expression(asyncResponse == null ? respond : AnnotatedExpression(PrivateAccess, respond, at),
						at)],
						identity, at);
				routes.push(AnnotatedExpression(PrivateAccess,
					MethodCall(descriptorValue, "route", [handler, Member(connectionValue, "finish", at)], at), at));
			} else {
				var call = MethodCall(connectionValue, "call", [descriptorValue, requestValue, argumentValue], at),
					stub = Lambda([parameter(request, requestType, at)], [Return(call, at)], identity, at);
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

	static function futurePayload(session:TypingSession, result:AstType):Null<AstType> {
		var name:String, arguments:Array<AstType>;
		switch result {
			case AppliedType(owner, [value]) if (owner == StdlibNames.FUTURE): return value;
			case AppliedType(owner, parameters): name = owner;
				arguments = parameters;
			case NamedType(owner): name = owner;
				arguments = [];
			default: return null;
		}
		var alias = session.declarations.aliases.get(name);
		if (alias == null || alias.typeParameters.length != arguments.length)
			return null;
		var substitutions = [for (i in 0...arguments.length) alias.typeParameters[i] => arguments[i]];
		return futurePayload(session, ImplicitConstructors.substitute(alias.type, substitutions));
	}

	static function parameter(local:TemporaryLocal, type:AstType, span:SourceSpan):AstArgument
		return {name: local.name, type: type, span: span, local: local};
}
