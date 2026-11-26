package compiler.types.typing;

import compiler.core.InternalError;
import compiler.core.Provides.ProviderOperation;
import compiler.core.Source.SourceSpan;
import compiler.types.Type.CompilerType;
import compiler.types.TypedAst.TypedFunction;
import compiler.types.typing.HelperRequests.HelperRequest;
import haxe.crypto.Sha256;

/**
 * The helpers that convert a `Dynamic` value to an anonymous structure or an array of structures: one per target type, whichever
 * functions convert to it, as the provider model has one function per operation and type. Typing records a request in the
 * unit's output (`request`); the helpers are generated from the program's merged requests once the bodies are typed, each body
 * built by `ConversionResolver.dynamicStructureBody` with the span of its type (`TypingSession.helperSpan`), never a requester's.
 */
class DynamicStructureGenerator {
	public static inline final PREFIX = "$dynamic-structure:";

	public static function name(target:CompilerType):String
		return PREFIX + Sha256.encode(compiler.semantic.SemanticSignature.type(target)).substr(0, 32);

	/** Requests the helper converting a `Dynamic` value to `target` for `origin`, and returns its name. */
	public static function request(session:TypingSession, target:CompilerType, origin:String, span:SourceSpan):String {
		var helper = name(target);
		session.requestHelper(DynamicStructureHelper(helper, {type: target, origin: origin, span: span}));
		return helper;
	}

	public static function generate(session:TypingSession, conversions:ConversionResolver,
			generated:Map<String, TypedFunction>):Array<TypedFunction> {
		var made:Array<TypedFunction> = [];
		while (true) {
			var pending = [
				for (helper in session.programOutput.requests.dynamicStructures.keys())
					if (!generated.exists(helper)) helper
			];
			if (pending.length == 0)
				break;
			pending.sort(Reflect.compare);
			for (helper in pending) {
				var request = session.programOutput.requests.dynamicStructures.get(helper);
				if (request == null)
					throw new InternalError('Missing dynamic structure request "$helper"');
				var context = session.enterHelperBody(helper, request.origin, "$dynamic-structure");
				try {
					var span = session.helperSpan(request.type, request.span),
						fn:TypedFunction = {
							name: helper,
							role: ProviderFunction(request.type, ProviderOperation.DynamicStructure),
							origin: request.origin,
							originKind: compiler.types.TypedAst.FunctionOriginKind.Helper,
							typeArguments: null,
							owner: null,
							isStatic: true,
							isConstructor: false,
							arguments: [{name: "source", type: TDynamic}],
							result: request.type,
							statements: conversions.dynamicStructureBody(request.type, span),
							cells: [],
							cellCaptures: [],
							span: span
						};
					generated.set(helper, fn);
					made.push(fn);
					session.leaveBody(context);
				} catch (error:haxe.Exception) {
					session.leaveBody(context);
					throw error;
				}
			}
		}
		return made;
	}
}
