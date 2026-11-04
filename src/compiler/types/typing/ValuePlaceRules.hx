package compiler.types.typing;

import compiler.Source.SourceSpan;
import compiler.Diagnostic;
import compiler.Diagnostic.CompileError;
import compiler.types.Type.CompilerType;
import compiler.types.Type.NominalKind;
import compiler.types.TypedAst.TypedExpression;

/** Writes to values must reach owned storage, rather than a discarded temporary copy. */
class ValuePlaceRules {
	public static function requireWritable(session:TypingSession, receiver:TypedExpression, span:SourceSpan):Void {
		if (!session.relations.isValueClass(receiver.type))
			return;
		rejectObservableMutation(session, receiver, span);
		checkPlace(session, receiver, span);
	}

	/** A bound mutating method can own a temporary value, but must not capture a tracked field place. */
	public static function rejectObservableMutation(session:TypingSession, receiver:TypedExpression, span:SourceSpan):Void {
		switch receiver.expression {
			case TField(parent, name):
				if (session.relations.isValueClass(parent.type) || session.relations.isNullableValueClass(parent.type))
					rejectObservableMutation(session, parent, span);
				else if (isObservableField(session, parent.type, name))
					throw new CompileError(new Diagnostic("E1027", 'Cannot mutate a struct inside Observable field "$name"; copy the value, mutate it, and assign it back', span));
			case TCast(value), TAbiCast(value):
				if (session.relations.isValueClass(value.type) || session.relations.isNullableValueClass(value.type))
					rejectObservableMutation(session, value, span);
			default:
		}
	}

	static function checkPlace(session:TypingSession, receiver:TypedExpression, span:SourceSpan):Void {
		switch receiver.expression {
			case TLocal(_), TCellLocal(_, _), TCaptured(_), TCellCaptured(_, _), TStaticField(_, _), TIndex(_, _):
			case TField(parent, name):
				if (session.relations.isValueClass(parent.type))
					FinalFieldRules.rejectInstanceMutation(session, parent, name, span);
				requireWritable(session, parent, span);
			case TCast(value), TAbiCast(value):
				if (session.relations.isValueClass(value.type) || session.relations.isNullableValueClass(value.type))
					checkPlace(session, value, span);
				else
					rejectTemporary(receiver, span);
			case TCall("$rawptr.ref.flat", _):
			default:
				rejectTemporary(receiver, span);
		}
	}

	/** Match the same stored, non-@:unobservable fields that receive reactive instrumentation. */
	static function isObservableField(session:TypingSession, type:CompilerType, name:String):Bool {
		if (!DeclaredConformance.has(session, type, "Observable")) return false;
		function find(current:CompilerType):Bool {
			return switch current {
				case TNullable(element): find(element);
				case TInstance(NominalKind.Class, className, _):
					var declaration = session.classDecls.get(className);
					if (declaration == null) false;
					else {
						var found:Null<compiler.syntax.Ast.AstField> = null;
						for (field in declaration.fields)
							if (!field.isStatic && field.name == name) { found = field; break; }
						if (found != null) {
							var ignored = false;
							for (metadata in found.metadata) if (metadata.name == "unobservable") ignored = true;
							!ignored && DiffIntrinsics.hasStoredField(found);
						} else if (declaration.base == null) false;
						else find(session.declarations.resolve(declaration.base, declaration.span, session.representation.nominalSubstitutions(current)));
					}
				default: false;
			};
		}
		return find(type);
	}

	static function rejectTemporary(receiver:TypedExpression, span:SourceSpan):Void {
		var origin = receiver.span;
		var expression = origin.file.slice(origin.start, origin.end);
		throw new CompileError(new Diagnostic("E1027", 'Cannot mutate temporary struct copy produced by "$expression"; bind it to a local first', span));
	}
}
