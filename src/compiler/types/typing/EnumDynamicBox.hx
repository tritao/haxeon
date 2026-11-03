package compiler.types.typing;

import compiler.Source.SourceSpan;
import compiler.types.Type.CompilerType;
import compiler.types.Type.NominalKind;
import compiler.types.TypedAst.TypedExpression;
import haxe.crypto.Sha256;

/** A Dynamic escape carries the concrete enum type needed by equality and reflection. */
class EnumDynamicBox {
	public static inline final PREFIX = "$enum-dynamic-box:";
	public static inline final VIEW_PREFIX = "$enum-dynamic-view:";

	public static function enumType(type:CompilerType):Null<CompilerType>
		return switch type {
			case TNullable(inner): enumType(inner);
			case TInstance(NominalKind.Enum, _, _): type;
			default: null;
		};

	public static function suffix(type:CompilerType):String
		return Sha256.encode(compiler.semantic.SemanticSignature.type(type)).substr(0, 32);

	public static function boxName(type:CompilerType):String return PREFIX + suffix(type);


	/** Reflection may expose enum values nested in any field container or generic owner. */
	public static function requestReflectedTypes(session:TypingSession, type:CompilerType, origin:String, span:SourceSpan,
			?seen:Array<Array<compiler.types.Type.AnonymousField>>):Void {
		if (seen == null) seen = [];
		switch type {
			case TInstance(NominalKind.Enum, _, arguments):
				if (!session.representation.containsTypeParameter(type, [])) {
					EnumEqualityGenerator.requestReflective(session, type, origin, span);
					if (DeclaredConformance.has(session, type, "Equatable")) EnumEqualityGenerator.request(session, type, origin, span);
				}
				for (argument in arguments) requestReflectedTypes(session, argument, origin, span, seen);
			case TInstance(_, _, arguments): for (argument in arguments) requestReflectedTypes(session, argument, origin, span, seen);
			case TAbstract(_, arguments, representation):
				for (argument in arguments) requestReflectedTypes(session, argument, origin, span, seen);
				requestReflectedTypes(session, representation, origin, span, seen);
			case TNullable(element), TArray(element), TIterator(element): requestReflectedTypes(session, element, origin, span, seen);
			case TMap(key, value): requestReflectedTypes(session, key, origin, span, seen); requestReflectedTypes(session, value, origin, span, seen);
			case TFunction(arguments, result):
				for (argument in arguments) requestReflectedTypes(session, argument, origin, span, seen);
				requestReflectedTypes(session, result, origin, span, seen);
			case TAnonymous(_, fields):
				if (seen.indexOf(fields) < 0) {
					seen.push(fields);
					for (field in fields) requestReflectedTypes(session, field.type, origin, span, seen);
					seen.pop();
				}
			default:
		}
	}

	/** Record the element conformance at an alias-preserving Dynamic array view. */
	public static function view(session:TypingSession, array:TypedExpression, type:CompilerType, span:SourceSpan):TypedExpression {
		EnumEqualityGenerator.requestReflective(session, type, session.currentContext.name, span);
		if (DeclaredConformance.has(session, type, "Equatable"))
			EnumEqualityGenerator.request(session, type, session.currentContext.name, span);
		var runtimeName = EnumRuntimeType.name(type), encoded = haxe.crypto.Base64.encode(haxe.io.Bytes.ofString(runtimeName));
		return new TypedExpression(TCall(VIEW_PREFIX + suffix(type) + ":" + encoded, [array]), array.type, span);
	}

	public static function box(session:TypingSession, value:TypedExpression, type:CompilerType, span:SourceSpan):TypedExpression {
		EnumEqualityGenerator.requestReflective(session, type, session.currentContext.name, span);
		if (DeclaredConformance.has(session, type, "Equatable"))
			EnumEqualityGenerator.request(session, type, session.currentContext.name, span);
		return new TypedExpression(TCall(boxName(type), [value]), TDynamic, span);
	}
}
