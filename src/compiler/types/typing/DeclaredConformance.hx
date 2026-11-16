package compiler.types.typing;

import compiler.types.Type.CompilerType;
import compiler.types.Type.NominalKind;
import compiler.core.Source.SourceSpan;
import compiler.runtime.RuntimeType;
import compiler.types.TypedAst;

/** Queries declared value capabilities using the same inheritance graph as interface bounds. */
class DeclaredConformance {
	public static function has(session:TypingSession, type:CompilerType, name:String):Bool
		return session.relations.satisfiesConstraint(type, TInstance(NominalKind.Interface, name, []));

	public static function usesEquality(session:TypingSession, type:CompilerType):Bool
		return switch type {
			case TKeyPath(_, _, _): true;
			case TArray(element): supportsEquality(session, element);
			case TAnonymous(_, _): has(session, type, "Equatable");
			case TNullable(element): usesEquality(session, element);
			case TInstance(NominalKind.Class, _, _): session.relations.isStruct(type)
				&& has(session, type, "Equatable");
			default: false;
		};

	/**
	 * A field can be synthesized only when its own equality is defined. An abstract's `==` compares its representation
	 * (or calls an `@:op(==)` overload, which only Int and Float abstracts may declare), and generated helpers compare
	 * elements through that same `==`, so every abstract has exactly its representation's equality.
	 */
	public static function supportsEquality(session:TypingSession, type:CompilerType):Bool
		return switch type {
			case TInt, TInt64, TFloat, TBool, TString, TNativeScalar(_), TKeyPath(_, _, _): true;
			case TAbstract(_, _, representation): supportsEquality(session, representation);
			case TNullable(element): supportsEquality(session, element);
			case TArray(element): supportsEquality(session, element);
			case TAnonymous(_, _): has(session, type, "Equatable");
			case TInstance(NominalKind.Class, _, _): session.relations.isStruct(type)
				&& has(session, type, "Equatable");
			case TInstance(NominalKind.Enum, _, _), TTypeParameter(_, _): has(session, type, "Equatable");
			default: false;
		};

	/**
	 * A plain abstract (not an enum abstract) compares as its representation. Returns the operand viewed as that
	 * representation, or null when it is not a plain abstract or its representation is a primitive that already
	 * compares correctly as it is.
	 */
	public static function abstractEqualityOperand(session:TypingSession,
			operand:TypedExpression):Null<TypedExpression> {
		var nullable = false, type = operand.type;
		switch type {
			case TNullable(element):
				nullable = true;
				type = element;
			default:
		}
		return switch type {
			case TAbstract(name, _, representation) if (!session.declarations.enumAbstracts.exists(name)):
				switch representation {
					case TInt | TInt64 | TFloat | TBool | TString | TNativeScalar(_): null;
					default: new TypedExpression(TCast(operand), nullable ? TNullable(representation) : representation,
						operand.span);
				}
			default: null;
		};
	}

	public static function supportsHash(session:TypingSession, type:CompilerType):Bool
		return switch type {
			case TInt, TInt64, TFloat, TBool, TString, TNativeScalar(_), TKeyPath(_, _, _): true;
			case TAbstract(name, _, representation) if (session.declarations.enumAbstracts.exists(name))
				: supportsHash(session, representation);
			case TNullable(element): supportsHash(session, element);
			case TAnonymous(_, _): has(session, type, "Hashable");
			case TInstance(NominalKind.Class, _, _): session.relations.isStruct(type) && has(session, type, "Hashable");
			case TInstance(NominalKind.Enum, _, _), TTypeParameter(_, _): has(session, type, "Hashable");
			default: false;
		};

	public static function capabilityError(session:TypingSession, type:CompilerType, capability:String):String {
		var field = session.relations.recursiveAnonymousField(type, [], null);
		var message = 'Type "${compiler.semantic.SemanticSignature.display(type)}" does not conform to $capability';
		return field == null
			? message : message + ' (recursive field "$field"; use a struct or class with explicit equals)';
	}

	/** Map operations need the same generated equality/hash helpers as ordinary value operations. */
	public static function requestHashableMapKey(session:TypingSession, type:CompilerType, span:SourceSpan):Void {
		if (session.isPayloadEnumKey(type)) {
			if (!has(session, type, "Hashable"))
				BodyTyper.fail("E1025", capabilityError(session, type, "Hashable"), span);
			HashGenerator.request(session, type, session.currentContext.name, span);
			EnumEqualityGenerator.request(session, type, session.currentContext.name, span);
			return;
		}
		if (RuntimeType.mapName(type, TInt) == null) {
			if (has(session, type, "Hashable")) {
				HashGenerator.request(session, type, session.currentContext.name, span);
				if (usesEquality(session, type))
					ValueEqualityGenerator.request(session, type, session.currentContext.name, span);
			} else
				BodyTyper.fail("E1025", capabilityError(session, type, "Hashable"), span);
		}
	}
}
