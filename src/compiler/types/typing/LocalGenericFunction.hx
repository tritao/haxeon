package compiler.types.typing;

import compiler.core.InternalError;
import compiler.core.Source.SourceSpan;
import compiler.semantic.SemanticSignature;
import compiler.syntax.Ast.AstFunction;
import compiler.syntax.AstFunctions;
import compiler.syntax.Parser;
import compiler.types.FunctionTypes;
import compiler.types.Monomorphs;
import compiler.types.Type.CompilerType;
import compiler.types.TypeRelations;
import compiler.types.TypedAst.TypedExpression;
import compiler.types.TypedAst.TypedStatement;

/** A lexical generic signature and the closure variants owned by its declaration. */
class LocalGenericFunction {
	public final signature:AstFunction;
	public final parameters:Array<String>;
	public final owner:String;
	public final enclosing:Map<String, CompilerType>;
	public final own:Map<String, CompilerType>;
	public final erased:Map<String, CompilerType> = [];
	public var semantic(default, null):CompilerType;
	public final physical:CompilerType;
	final physicalResult:CompilerType;
	final variants:Map<String, Int> = [];
	final initializers:Array<TypedStatement> = [];
	var familyBinding:String;
	var compileVariant:(Map<String, CompilerType>, CompilerType, String) -> TypedExpression;

	public function initialize(binding:String, closure:TypedExpression,
			compileVariant:(Map<String, CompilerType>, CompilerType, String) -> TypedExpression):Array<TypedStatement> {
		this.familyBinding = binding;
		this.compileVariant = compileVariant;
		var span = signature.span, family = new TypedExpression(TLocal(binding), TArray(TDynamic), span);
		initializers.push(push(family, closure));
		return [
			TVar(binding, new TypedExpression(TArrayLiteral([]), TArray(TDynamic), span), span),
			TExpression(new TypedExpression(TBlockExpression(initializers,
				new TypedExpression(TIntLiteral(0), TInt, span)), TInt, span), span)
		];
	}

	function push(family:TypedExpression, closure:TypedExpression):TypedStatement {
		var span = family.span;
		return TExpression(new TypedExpression(TArrayPush(family,
			new TypedExpression(TToDynamic(closure), TDynamic, span)), TInt, span), span);
	}

	/** Select the closure after inference fixes its ABI, including types fixed by later statements. */
	public function value(session:TypingSession, family:TypedExpression, substitutions:Map<String, CompilerType>,
			type:CompilerType):TypedExpression {
		if (compileVariant == null || !Monomorphs.containsUnbound(type))
			return session.representation.boundaryCast(callee(session, family, substitutions), type);
		var span = family.span,
			context = session.currentContext,
			name = "$local-generic-value:" + session.counters.nextFunctionAdapter(context.name),
			statements:Array<TypedStatement> = [];
		session.monomorphs.whenKnown(type, () -> session.withLexicalContext(context, () -> {
			var target = session.monomorphs.settled(type),
				value = session.representation.boundaryCast(callee(session, family, substitutions), target);
			statements.push(TVar(name, value, span));
		}));
		return new TypedExpression(TBlockExpression(statements, new TypedExpression(TLocal(name), type, span)),
			type, span);
	}

	function callee(session:TypingSession, family:TypedExpression,
			substitutions:Map<String, CompilerType>):TypedExpression {
		var type = physical, index = 0;
		var enclosingRepresentation = session.currentContext.localTypeRepresentation;
		var concrete = substitutions.copy();
		if (enclosingRepresentation != null)
			for (parameter in parameters)
				concrete.set(parameter, enclosingRepresentation(concrete.get(parameter)));
		var actuals = [for (parameter in parameters) session.monomorphs.closeReached(concrete.get(parameter))];
		for (index in 0...parameters.length)
			concrete.set(parameters[index], actuals[index]);
		var known = compileVariant != null;
		for (actual in actuals)
			if (Monomorphs.containsUnbound(actual) || session.representation.containsTypeParameter(actual, []))
				known = false;
		if (known) {
			type = instantiate(concrete, session.relations);
			if (Lambda.exists(actuals, actual -> !actual.match(TDynamic))) {
				var key = SemanticSignature.type(TFunction(actuals, TVoid, []));
				var existing = variants.get(key);
				if (existing == null) {
					index = initializers.length;
					variants.set(key, index);
					// Reserve the slot before typing the body so recursive calls find the same variant.
					initializers.push(null);
					var local = new TypedExpression(TLocal(familyBinding), TArray(TDynamic), signature.span);
					initializers[index] = push(local, compileVariant(concrete, type, key));
				} else
					index = existing;
			}
		}
		var span = family.span;
		return new TypedExpression(TAbiCast(new TypedExpression(TIndex(family,
			new TypedExpression(TIntLiteral(index), TInt, span)), TDynamic, span)), type, span);
	}

	public function new(session:TypingSession, signature:AstFunction, owner:String) {
		this.signature = signature;
		this.owner = owner;
		parameters = BodyTyper.functionTypeParameters(signature);
		enclosing = [for (name => type in session.currentContext.typeSubstitutions)
			if (parameters.indexOf(name) == -1) name => type];
		own = enclosing.copy();
		for (parameter in parameters) {
			own.set(parameter, TTypeParameter(owner, parameter));
			erased.set(parameter, TDynamic);
		}
		session.declarations.indexLocalTypeParameters(owner, own, signature.typeConstraints ?? []);
		var arguments = [for (argument in signature.arguments)
			AstFunctions.isInferred(argument.type)
			? variable(session, 'the type of parameter "${argument.name}"', argument.span)
			: session.declarations.resolve(Parser.localParameterType(argument), argument.span, own)];
		var inferred = AstFunctions.isInferred(signature.result);
		var result = inferred ? variable(session, 'the result of "${signature.name}"', signature.span)
			: session.declarations.resolve(signature.result, signature.span, own);
		var optional = FunctionTypes.ofArguments(signature.arguments);
		semantic = TFunction(arguments, result, optional);
		physicalResult = inferred ? variable(session, 'the closure result of "${signature.name}"', signature.span)
			: erase(result);
		physical = TFunction([for (index in 0...arguments.length)
			erase(DefaultArguments.dispatchType(signature.arguments[index], arguments[index], session.relations))],
			physicalResult, optional);
	}

	public function finish(result:CompilerType, elaboration:GenericElaboration):Void {
		if (AstFunctions.isInferred(signature.result))
			Monomorphs.close(physicalResult, elaboration.type(result));
		semantic = Monomorphs.resolve(semantic);
	}

	public function instantiate(substitutions:Map<String, CompilerType>,
			relations:TypeRelations):CompilerType
		return switch GenericElaboration.substitute(semantic, [owner], substitutions) {
			case TFunction(arguments, result, optional):
				TFunction([for (index in 0...arguments.length)
					DefaultArguments.dispatchType(signature.arguments[index], arguments[index], relations)], result,
					optional);
			default:
				throw new InternalError("Generic local without a function type");
		};

	function erase(type:CompilerType):CompilerType
		return GenericElaboration.substitute(type, [owner], erased);

	public static function variable(session:TypingSession, origin:String, span:SourceSpan):CompilerType
		return session.monomorphs.create(origin, span) ?? TDynamic;
}
