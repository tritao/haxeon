package compiler.types;

import compiler.types.Type.CompilerType;
import compiler.types.Type.AnonymousField;
import compiler.types.Type.NominalKind;
import compiler.semantic.SemanticSignature;
import compiler.Diagnostic;
import compiler.Diagnostic.CompileError;
import compiler.types.TypedAst.TypedExpression;
import compiler.types.typing.TypingSession;

/** Structural collection contracts. Concrete loops retain the receiver's own representation. */
class IterationProtocol {
	public static function contract(name:String, element:CompilerType):CompilerType {
		var fields:Array<AnonymousField> = name == "Iterator" ? [
			{
				name: "hasNext",
				type: TFunction([], TBool),
				optional: false,
				isFinal: true
			},
			{
				name: "next",
				type: TFunction([], element),
				optional: false,
				isFinal: true
			}
		] : [
			{
				name: "iterator",
				type: TFunction([], contract("Iterator", element)),
				optional: false,
				isFinal: true
			}
			];
		return TAnonymous(SemanticSignature.anonymousTypeName(fields), fields);
	}

	public static function name(type:CompilerType):Null<String>
		return switch type {
			case TAnonymous(_, fields) if (iteratorFields(fields)): "Iterator";
			case TAnonymous(_, [field]) if (field.name == "iterator" && field.isFinal && !field.optional):
				switch field.type {
					case TFunction([], TAnonymous(_, fields)) if (iteratorFields(fields)): "Iterable";
					default: null;
				}
			default: null;
		};

	static function iteratorFields(fields:Array<AnonymousField>):Bool {
		if (fields.length != 2)
			return false;
		var hasNext = false, next = false;
		for (field in fields) {
			if (!field.isFinal || field.optional)
				return false;
			switch field.name {
				case "hasNext":
					hasNext = switch field.type {
						case TFunction([], TBool): true;
						default: false;
					};
				case "next":
					next = switch field.type {
						case TFunction([], _): true;
						default: false;
					};
				default:
					return false;
			}
		}
		return hasNext && next;
	}

	public static function method(declarations:DeclarationIndex, type:CompilerType, name:String):Null<{type:CompilerType, owner:Null<String>}> {
		switch type {
			case TArray(element):
				if (name == "iterator")
					return {type: TFunction([], TIterator(element)), owner: null};
			case TMap(_, element):
				if (name == "iterator")
					return {type: TFunction([], TIterator(element)), owner: null};
			case TIterator(element):
				if (name == "hasNext")
					return {type: TFunction([], TBool), owner: null};
				if (name == "next")
					return {type: TFunction([], element), owner: null};
			case TAnonymous(_, fields):
				for (field in fields)
					if (field.name == name && !field.optional)
						return {type: field.type, owner: null};
			case TInstance(kind, owner, _) if (kind == NominalKind.Class || kind == NominalKind.Interface):
				var methods:Array<compiler.syntax.Ast.AstFunction>;
				if (kind == NominalKind.Class) {
					var declaration = declarations.classes.get(owner);
					if (declaration == null)
						return null;
					methods = declaration.methods;
				} else {
					var declaration = declarations.interfaces.get(owner);
					if (declaration == null)
						return null;
					methods = declaration.methods;
				}
				for (method in methods)
					if (method.name == name && !method.isStatic && (method.typeParameters == null || method.typeParameters.length == 0)) {
						var substitutions = declarations.inheritance.substitutions(type);
						return {
							type: TFunction([
								for (argument in method.arguments)
									declarations.resolve(argument.type, argument.span, substitutions)
							], declarations.resolve(method.result, method.span, substitutions)),
							owner: owner
						};
					}
				if (kind == NominalKind.Class) {
					var declaration = declarations.classes.get(owner);
					if (declaration != null)
						for (field in declaration.fields)
							if (field.name == name && !field.isStatic)
								return {
									type: declarations.resolve(declarations.resolvedFieldType(owner, field), field.span,
										declarations.inheritance.substitutions(type)),
									owner: null
								};
				}
				for (parent in declarations.inheritance.parents(type)) {
					var found = method(declarations, parent, name);
					if (found != null)
						return found;
				}
			default:
		}
		return null;
	}

	public static function result(declarations:DeclarationIndex, type:CompilerType, name:String):Null<CompilerType> {
		var found = method(declarations, type, name);
		return found == null ? null : switch found.type {
			case TFunction([], result): result;
			default: null;
		};
	}

	public static function element(declarations:DeclarationIndex, type:CompilerType, iterable:Bool):Null<CompilerType> {
		if (iterable) {
			var iterator = result(declarations, type, "iterator");
			return iterator == null ? null : element(declarations, iterator, false);
		}
		var next = result(declarations, type, "next");
		return result(declarations, type, "hasNext") == TBool && next != TVoid && next != TNever ? next : null;
	}

	public static function conforms(declarations:DeclarationIndex, relations:TypeRelations, actual:CompilerType, expected:CompilerType):Bool {
		return switch expected {
			case TAnonymous(_, fields):
				var valid = true;
				for (field in fields) {
					var found = method(declarations, actual, field.name);
					if (found == null || !relations.isAssignable(found.type, field.type))
						valid = false;
				}
				valid;
			default: false;
		};
	}

	/** A typed call, preserving normal class dispatch and generic method ABIs. */
	public static function call(session:TypingSession, receiver:TypedExpression, name:String):TypedExpression {
		var span = receiver.span,
			found = method(session.declarations, receiver.type, name);
		if (found == null)
			throw new CompileError(new Diagnostic("E1014", 'Iteration requires "$name()"', span));
		var result = switch found.type {
			case TFunction([], result): result;
			default: throw new CompileError(new Diagnostic("E1014", 'Iteration requires a zero-argument "$name()"', span));
		};
		var expression:TypedExpression;
		switch receiver.type {
			case TArray(_), TMap(_, _) if (name == "iterator"):
				var values = switch receiver.type {
					case TMap(_, element): new TypedExpression(TCollectionCall(receiver, "values", []), TArray(element), span);
					default: receiver;
				};
				var dynamicValues = new TypedExpression(TToDynamic(values), TDynamic, span);
				expression = new TypedExpression(TCall("__iterator_new", [dynamicValues]), result, span);
			case TIterator(_):
				expression = new TypedExpression(TCall(name == "next" ? "__iterator_next" : "__iterator_has_next", [receiver]), result, span);
			case _ if (found.owner == null):
				var representation = session.representation.resolveField(receiver.type, name, span);
				var physicalResult = switch representation.physical {
					case TFunction([], result): result;
					default: throw "Expected callable iteration field";
				};
				var field = new TypedExpression(TField(receiver, name), representation.physical, span);
				expression = session.representation.boundaryCast(new TypedExpression(TClosureCall(field, []), physicalResult, span), result);
			default:
				var signature = session.signatures.get(found.owner + "." + name);
				if (signature == null)
					throw new CompileError(new Diagnostic("E1007", 'Missing iteration method signature "$name"', span));
				var physical = session.representation.resolveMethodResult(receiver.type, found.owner, signature).physical;
				expression = session.representation.boundaryCast(new TypedExpression(TMethodCall(receiver, found.owner + "." + name, []), physical, span),
					result);
		}
		return expression;
	}

	/** Implicit user calls have the same conservative effects as an unknown closure call. */
	public static function invalidateEffects(session:TypingSession, scope:compiler.types.analysis.Scope):Void {
		for (captured in session.currentContext.storage.candidateSourceNames())
			scope.invalidate(captured);
		scope.invalidateAllExpressions();
	}

	public static function structuralIterator(type:CompilerType):Bool
		return switch type {
			case TInstance(NominalKind.Class, _, _), TInstance(NominalKind.Interface, _, _), TAnonymous(_, _): true;
			default: false;
		};
}
