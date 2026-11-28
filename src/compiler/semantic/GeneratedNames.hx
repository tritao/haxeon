package compiler.semantic;

/**
 * The names of generated generic code, and the tests for them, in one place: the typer, the elaboration pass and the IR all name
 * and recognize them through here (docs/design/GENERIC_TYPING_ONCE.md, stage 2, the naming contract with the IR lane). Today the
 * names are text; ADR 0003 M3 replaces the text with a structured identity behind these functions.
 */
class GeneratedNames {
	static inline final SPECIALIZATION_PREFIX = "$generic:";
	static inline final OWNER_ORIGIN_PREFIX = "$owner:";
	static inline final OWNER_SPECIALIZATION_PREFIX = "$generic:$owner:";
	static inline final ERASED_PREFIX = "$generic-erased:";
	static inline final ERASED_DISPATCH_PREFIX = "$generic-erased-dispatch:";

	/**
	 * The key of a specialization of `origin` (a function, `Owner.method`, or an owner, `ownerOrigin`) under `policy` for the
	 * representations spelled `signature`: `origin[policy]<signature>`.
	 */
	public static function specializationKey(origin:String, policy:String, signature:String):String
		return compiler.core.GlobalNames.of(origin + "[" + policy + "]<" + signature + ">");

	/** The function or owner name of the specialization keyed `key`: `$generic:key`. */
	public static function specialization(key:String):String
		return compiler.core.GlobalNames.of(SPECIALIZATION_PREFIX + key);

	/** The origin a generic owner's specializations are keyed by: `$owner:Owner`. */
	public static function ownerOrigin(owner:String):String
		return OWNER_ORIGIN_PREFIX + owner;

	/** Whether `name` names a specialization of a generic function or owner. */
	public static inline function isSpecialization(name:String):Bool
		return StringTools.startsWith(name, SPECIALIZATION_PREFIX);

	/** Whether `name` names a specialization of a generic owner or one of its members (a method, a field's initializer). */
	public static inline function inOwnerSpecialization(name:String):Bool
		return StringTools.startsWith(name, OWNER_SPECIALIZATION_PREFIX);

	/** Whether `name` names a specialization of a generic owner (`$generic:$owner:Owner[...]<...>`), not one of its members. */
	public static inline function isOwnerSpecialization(name:String):Bool
		return StringTools.startsWith(name, OWNER_SPECIALIZATION_PREFIX) && StringTools.endsWith(name, ">");

	/**
	 * The generic function a specialization `name` was made from (`Owner.method` for a method of a specialized owner), or `name`
	 * when it is no specialization.
	 */
	public static function specializationOrigin(name:String):String {
		if (!isSpecialization(name))
			return name;
		if (StringTools.startsWith(name, OWNER_SPECIALIZATION_PREFIX)) {
			var end = name.indexOf("[", OWNER_SPECIALIZATION_PREFIX.length), method = name.lastIndexOf(">.");
			if (end >= 0 && method > end)
				return name.substring(OWNER_SPECIALIZATION_PREFIX.length, end) + "." + name.substr(method + 2);
		}
		var end = name.indexOf("[", SPECIALIZATION_PREFIX.length);
		return end < 0 ? name : name.substring(SPECIALIZATION_PREFIX.length, end);
	}

	/** The generic function or owner origin a specialization `name` was keyed by (`origin` before `[`), or `name` itself. */
	public static function specializedFunction(name:String):String {
		if (!isSpecialization(name))
			return name;
		var bracket = name.indexOf("[", SPECIALIZATION_PREFIX.length);
		return bracket > 0 ? name.substring(SPECIALIZATION_PREFIX.length, bracket) : name;
	}

	/** An operation (`get`, `set`, `call`) on `member` through the erased generic owner `owner`: `$generic-erased:Owner:op:member`. */
	public static function erasedOperation(owner:String, operation:String, member:String):String
		return ERASED_PREFIX + owner + ":" + operation + ":" + member;

	/** Whether `name` is an operation through an erased generic owner (`erasedOperation`). */
	public static inline function isErasedOperation(name:String):Bool
		return StringTools.startsWith(name, ERASED_PREFIX);

	/** The text after `$generic-erased:` in an erased operation's name: `Owner:op:member`. */
	public static inline function erasedOperationPath(name:String):String
		return name.substr(ERASED_PREFIX.length);

	/** The full accessor behind an erased operation's inlinable fast path: `$generic-erased-dispatch:Owner:op:member`. */
	public static function erasedDispatch(owner:String, operation:String, member:String):String
		return ERASED_DISPATCH_PREFIX + owner + ":" + operation + ":" + member;
}
