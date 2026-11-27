package compiler.types.typing;

import compiler.core.DiagnosticCode;
import compiler.core.Source.SourceSpan;
import compiler.core.StdlibNames;
import compiler.types.Type.CompilerType;
import compiler.types.Type.NominalKind;
import compiler.types.TypedAst.TypedExpression;

/**
 * Members of a value whose type is a type parameter, as Haxe types them: through the parameter's constraints, in the order they
 * are written. `function measure<T:Measured>(value:T) return value.measure()` calls `Measured.measure`, and with
 * `T:(Readable, Writable)` a member is the first constraint's that has it.
 *
 * A body sees its type parameters as themselves only where it is typed for its errors or its signature (a generic function nothing
 * calls, an abstract's member); its code is each specialization's, where the parameter is the type argument.
 */
class TypeParameterMembers {
	/**
	 * `receiver` as the bound of its type parameter that has the member `name` (accessed at `span`); `receiver` itself when its
	 * type is not a type parameter. A type parameter none of whose bounds has the member has no such field, as Haxe reports it
	 * (`measure.T has no field size`), at the member's name.
	 */
	public static function receiver(session:TypingSession, bodyTyper:BodyTyping, receiver:TypedExpression, name:String,
			span:SourceSpan):TypedExpression {
		var display = switch receiver.type {
			case TTypeParameter(owner, parameter):
				var ownerName:String = owner;
				ownerName.substr(ownerName.lastIndexOf(".") + 1) + "." + parameter;
			default:
				return receiver;
		};
		for (bound in session.declarations.typeParameterBounds(receiver.type))
			if (hasMember(session, bodyTyper, bound, name))
				return new TypedExpression(TCast(receiver), bound, receiver.span);
		// A missing member, so a call tries the static extensions of the value (through its bounds, `StaticExtensions`).
		throw new MissingMember(DiagnosticCode.NAME_OR_MEMBER, '$display has no field $name', span,
			AbstractProperties.nameSpan(span, name, true));
	}

	/**
	 * The signature of a member the compiler synthesizes for the enum abstracts a capability bound of `receiver`'s type parameter
	 * stands for (`T:Flags`): `value.rawValue`, `flags.insert(other)`. Each specialization calls the
	 * abstract's own; typed with the parameter as itself, the call is checked against this signature, the parameter as the
	 * abstract, and a raw value, Int or String by the abstract, is Dynamic. Null for any other member or receiver.
	 */
	public static function synthesizedMember(session:TypingSession, receiver:TypedExpression,
			name:String):Null<{
				arguments:Array<CompilerType>,
				result:CompilerType
			}> {
		var self = receiver.type;
		switch self {
			case TTypeParameter(_, _):
			default:
				return null;
		}
		for (bound in session.declarations.typeParameterBounds(self))
			switch bound {
				case TInstance(NominalKind.Interface, StdlibNames.FLAGS, _) if (FlagsGenerator.isMember(name, false)):
					var signature = FlagsGenerator.signature(StdlibNames.FLAGS, name);
					return {arguments: [for (index in 1...signature.arguments.length) self],
						result: switch signature.result {
							case TAbstract(_, _, _): self;
							default: signature.result;
						}
					};
				default:
			}
		return null;
	}

	static function hasMember(session:TypingSession, bodyTyper:BodyTyping, type:CompilerType, name:String):Bool {
		if (bodyTyper.findFieldType(type, name) != null)
			return true;
		return switch type {
			case TInstance(NominalKind.Class | NominalKind.Interface, owner, _):
				MemberAccess.methodInfo(session, owner, name) != null;
			case TAbstract(owner, _, _):
				session.signatures.exists(owner + "." + name);
			default: false;
		};
	}
}
