package compiler.types.typing;

import compiler.Source.SourceSpan;
import compiler.syntax.Ast.AstExpression;
import compiler.types.Type.CompilerType;
import compiler.types.TypedAst.TypedExpression;
import compiler.types.TypedAst.TypedStatement;
import compiler.types.TypeRelations;
import compiler.types.analysis.Scope;
import compiler.types.typing.CallResolver.TypeExpressionCallback;
import compiler.types.typing.CallResolver.CoerceCallback;
import compiler.types.typing.CallResolver.TypeCallMemberWithFlowCallback;

/** Path operations preserve typed field access instead of crossing Dynamic. */
class KeyPathOperations {
	public static function call(session:TypingSession, receiver:TypedExpression, name:String, arguments:Array<AstExpression>, span:SourceSpan,
			scope:Scope, typeExpression:TypeExpressionCallback, coerce:CoerceCallback,
			member:TypeCallMemberWithFlowCallback):Null<TypedExpression> {
		return switch receiver.type {
			case TKeyPath(root, value, writable) if (name == "then"):
				if (arguments.length != 1) fail("E1008", "KeyPath.then expects 1 argument", span);
				var next = typeExpression(arguments[0], scope, null, false);
				switch next.type {
					case TKeyPath(nextRoot, result, nextWritable):
						if (!TypeRelations.equals(value, nextRoot)) fail("E1009", "KeyPath.then requires matching intermediate types", span);
						var first = KeyPathTyping.known(session, receiver), second = KeyPathTyping.known(session, next);
						if (first != null && second != null)
							KeyPathTyping.define(session, root, result, first.fields.concat(second.fields), writable && nextWritable, span, false);
						else {
							if (writable && nextWritable && session.relations.isValueClass(value)
								&& (second == null || second.rootWriteback)
								&& KeyPathTyping.mayProjectTrackedStruct(session, root, first))
								fail("E1027", "Cannot mutate a struct inside Observable storage through an unknown composed path; compose a read-only KeyPath instead", span);
							KeyPathComposition.create(session, receiver, next, root, value, result, writable && nextWritable, span);
						}
					default:
						fail("E1009", "KeyPath.then requires a key path", span);
						null;
				}
			case TKeyPath(root, value, _) if (name == "toString"):
				if (arguments.length != 0) fail("E1008", "KeyPath.toString expects no arguments", span);
				new AnonymousTypeRegistry(session).register(receiver.type);
				new TypedExpression(TField(receiver, "$display"), TString, span);
			case TKeyPath(root, value, _) if (name == "get"):
				if (arguments.length != 1)
					throw new compiler.Diagnostic.CompileError(new compiler.Diagnostic("E1008", 'KeyPath.get expects 1 argument, got ${arguments.length}', span));
				var target = coerce(typeExpression(arguments[0], scope, root, false), root, "key path root", "E1009"),
					definition = KeyPathTyping.known(session, receiver);
				if (definition != null) {
					for (entry in definition.fields)
						target = member(target, entry.field.name, span, scope);
					target;
				} else {
					new AnonymousTypeRegistry(session).register(receiver.type);
					new TypedExpression(TClosureCall(new TypedExpression(TField(receiver, "$get"), TFunction([root], value), span), [target]), value, span);
				}
			case TKeyPath(root, value, writable) if (name == "set"):
				if (arguments.length != 2) fail("E1008", 'KeyPath.set expects 2 arguments, got ${arguments.length}', span);
				var definition = KeyPathTyping.known(session, receiver);
				if (!writable || definition != null && !definition.writable) {
					var message = definition != null && definition.writeError != null ? definition.writeError : "Cannot write through a read-only KeyPath";
					fail(StringTools.startsWith(message, "Cannot mutate a struct inside Observable") ? "E1027" : "E1009", message, span);
				}
				var target = typeExpression(arguments[0], scope, root, false);
				if (!session.relations.isAssignable(target.type, root)) fail("E1009", "Type mismatch for key path root", target.span);
				// A place must retain its storage: ordinary argument coercion copies structs.
				if (!TypeRelations.equals(target.type, root)) target = session.representation.boundaryCast(target, root);
				if (definition != null) {
					for (index in 0...definition.fields.length - 1)
						target = member(target, definition.fields[index].field.name, span, scope);
					ValuePlaceRules.requireWritable(session, target, span);
					var last = definition.fields[definition.fields.length - 1],
						assigned = coerce(typeExpression(arguments[1], scope, value, false), value, "key path value", "E1009"),
						physical = session.representation.resolveField(target.type, last.field.name, span).physical;
					new TypedExpression(TBlockExpression([TFieldAssign(target, last.field.name,
						session.representation.boundaryCast(assigned, physical), span)], new TypedExpression(TVoidLiteral, TVoid, span)), TVoid, span);
				} else {
					ValuePlaceRules.requireWritable(session, target, span);
					var statements:Array<TypedStatement> = [], path = hold(session, receiver, "path", span, statements),
						place = session.relations.isValueClass(root) ? capturePlace(session, target, span, statements)
							: hold(session, target, "root", span, statements),
						assigned = hold(session, coerce(typeExpression(arguments[1], scope, value, false), value, "key path value", "E1009"), "value", span, statements),
						rootValue = session.relations.isValueClass(root) ? hold(session, ValueCopy.bind(session, place, root), "root", span, statements) : place;
					new AnonymousTypeRegistry(session).register(receiver.type);
					var setter = new TypedExpression(TField(path, "$set"), TFunction([root, value], root), span),
						updated = new TypedExpression(TClosureCall(setter, [rootValue, assigned]), root, span);
					if (session.relations.isValueClass(root)) {
						var result = hold(session, updated, "updated", span, statements),
							writesRoot = new TypedExpression(TField(path, "$writeback"), TBool, span);
						statements.push(TIf(writesRoot, storePlace(session, place, result, span), [], span));
					} else statements.push(TExpression(updated, span));
					new TypedExpression(TBlockExpression(statements, new TypedExpression(TVoidLiteral, TVoid, span)), TVoid, span);
				}
			default: null;
		};
	}

	public static function hold(session:TypingSession, value:TypedExpression, purpose:String, span:SourceSpan, statements:Array<TypedStatement>):TypedExpression {
		var name = "$keypath:" + purpose + ":" + span.start + ":" + session.currentContext.keyPathTemporary++;
		statements.push(TVar(name, value, span));
		return new TypedExpression(TLocal(name), value.type, span);
	}

	/** Capture reference receivers and indices once, without copying an enclosing struct place. */
	static function capturePlace(session:TypingSession, place:TypedExpression, span:SourceSpan, statements:Array<TypedStatement>):TypedExpression
		return switch place.expression {
			case TField(parent, name):
				var receiver = session.relations.isValueClass(parent.type) || session.relations.isNullableValueClass(parent.type)
					? capturePlace(session, parent, span, statements) : hold(session, parent, "owner", span, statements);
				new TypedExpression(TField(receiver, name), place.type, place.span);
			case TIndex(array, index):
				var receiver = hold(session, array, "array", span, statements), offset = hold(session, index, "index", span, statements);
				new TypedExpression(TIndex(receiver, offset), place.type, place.span);
			case TCast(inner): new TypedExpression(TCast(capturePlace(session, inner, span, statements)), place.type, place.span);
			case TAbiCast(inner): new TypedExpression(TAbiCast(capturePlace(session, inner, span, statements)), place.type, place.span);
			default: place;
		};

	static function storePlace(session:TypingSession, place:TypedExpression, value:TypedExpression, span:SourceSpan):Array<TypedStatement>
		return switch place.expression {
			case TLocal(_) if (session.relations.isValueClass(place.type)): copyFields(session, place, value, span);
			case TLocal(name): [TAssign(name, value, span)];
			case TCellLocal(name, cell): [TCellAssign(name, cell, value, span)];
			case TCellCaptured(name, cell): [TCellCapturedAssign(name, cell, value, span)];
			case TField(parent, name): [TFieldAssign(parent, name, value, span)];
			case TStaticField(_, _) if (session.relations.isValueClass(place.type)):
				// Static value storage already owns its box. Copy lanes back into it instead
				// of allocating a new object for the accessor's scalar result on every write.
				copyFields(session, place, value, span);
			case TStaticField(owner, name): [TStaticFieldAssign(owner, name, value, span)];
			case TIndex(array, index): [TIndexAssign(array, index, value, span)];
			case TCast(inner), TAbiCast(inner):
				var assigned = switch inner.type {
					case TNullable(_): new TypedExpression(TNullableWrap(value), inner.type, span);
					default: new TypedExpression(TCast(value), inner.type, span);
				};
				storePlace(session, inner, assigned, span);
			default: throw "Unsupported key path root place";
		};

	static function copyFields(session:TypingSession, place:TypedExpression, value:TypedExpression, span:SourceSpan):Array<TypedStatement>
	{
		var statements:Array<TypedStatement> = [];
		for (entry in DiffIntrinsics.conformanceFields(session, place.type)) {
			var physical = session.representation.resolveField(place.type, entry.field.name, span).physical;
			var source = new TypedExpression(TField(value, entry.field.name), physical, span);
			if (session.relations.isValueClass(entry.type)) {
				var destination = new TypedExpression(TField(place, entry.field.name), physical, span);
				for (statement in copyFields(session, destination, source, span)) statements.push(statement);
			} else statements.push(TFieldAssign(place, entry.field.name, source, span));
		}
		return statements;
	}

	static function fail(code:String, message:String, span:SourceSpan):Void
		throw new compiler.Diagnostic.CompileError(new compiler.Diagnostic(code, message, span));
}
