package compiler.types.typing;

import compiler.types.Type.CompilerType;
import compiler.types.Type.NominalKind;
import compiler.Source.SourceSpan;
import compiler.runtime.RuntimeType;

/** Queries declared value capabilities using the same inheritance graph as interface bounds. */
class DeclaredConformance {
	public static function has(session:TypingSession, type:CompilerType, name:String):Bool
		return session.relations.satisfiesConstraint(type, TInstance(NominalKind.Interface, name, []));

	public static function usesEquality(session:TypingSession, type:CompilerType):Bool
		return switch type {
			case TNullable(element): usesEquality(session, element);
			case TInstance(NominalKind.Class, _, _): has(session, type, "Equatable");
			default: false;
		};

	/** A field can be synthesized only when its own equality is defined. */
	public static function supportsEquality(session:TypingSession, type:CompilerType):Bool
		return switch type {
			case TInt, TInt64, TFloat, TBool, TString, TNativeScalar(_): true;
			case TAbstract(name, _, representation) if (session.declarations.enumAbstracts.exists(name)): supportsEquality(session, representation);
			case TNullable(element): supportsEquality(session, element);
			case TInstance(NominalKind.Class, _, _), TInstance(NominalKind.Enum, _, _), TTypeParameter(_, _): has(session, type, "Equatable");
			default: false;
		};

	public static function supportsHash(session:TypingSession, type:CompilerType):Bool
		return switch type {
			case TInt, TInt64, TFloat, TBool, TString, TNativeScalar(_): true;
			case TAbstract(name, _, representation) if (session.declarations.enumAbstracts.exists(name)): supportsHash(session, representation);
			case TNullable(element): supportsHash(session, element);
			case TInstance(NominalKind.Class, _, _), TInstance(NominalKind.Enum, _, _), TTypeParameter(_, _): has(session, type, "Hashable");
			default: false;
		};

	/** Map operations need the same generated equality/hash helpers as ordinary value operations. */
	public static function requestHashableMapKey(session:TypingSession, type:CompilerType, span:SourceSpan):Void {
		if (session.isPayloadEnumKey(type)) {
			if (!has(session, type, "Hashable"))
				BodyTyper.fail("E1025", 'Type "${compiler.semantic.SemanticSignature.display(type)}" does not conform to Hashable', span);
			HashGenerator.request(session, type, session.currentContext.name, span);
			EnumEqualityGenerator.request(session, type, session.currentContext.name, span);
			return;
		}
		if (RuntimeType.mapName(type, TInt) == null) {
			if (has(session, type, "Hashable")) {
				HashGenerator.request(session, type, session.currentContext.name, span);
				ValueEqualityGenerator.request(session, type, session.currentContext.name, span);
			} else switch type {
				case TInstance(NominalKind.Class, _, _):
					BodyTyper.fail("E1025", 'Type "${compiler.semantic.SemanticSignature.display(type)}" does not conform to Hashable', span);
				default:
			}
		}
	}
}
