package compiler.types.typing;

import compiler.types.Monomorphs;
import compiler.types.Type.AnonymousField;
import compiler.types.Type.CompilerType;
import compiler.types.Type.NominalKind;
import compiler.types.TypedAst.TypedAnonymous;

/**
 * What types give the program's registries: the structures and key path descriptors they reach (`TypingSession.anonymousTypes`),
 * the enum specializations (`EnumRuntimeRepresentations`), and the class instances with arguments and the maps that may need a
 * generic owner (`TypeRepresentation.genericOwner`), each in the order the walk meets it. This is the one walk of types for those
 * registries: a body's types are collected and registered at once (`AnonymousTypeRegistry.register`,
 * `EnumRuntimeRepresentations.discover`), and a declaration's are collected once and kept while it is the same object
 * (`TypedProgramAssembler.registerProgramTypes`, `SessionState.programTypeUses`). What is registered already stays as it is, so
 * registering the same uses again changes nothing. Whether an instance needs an owner, or a map which one, reads the program's
 * declarations, so that is decided when the uses are registered.
 *
 * The walk makes the uses when it first meets something to register, so types that reach nothing (most of them) give null and
 * cost no allocation.
 */
class ProgramTypeUses {
	/** The typed object a declaration's uses were made of: a function, the natives, or a class's fields. */
	public var source(default, null):Any = null;

	public var structures(default, null):Null<Array<TypedAnonymous>> = null;

	var structureNames:Null<Map<String, Bool>> = null;
	var enumNames:Null<Array<String>> = null;
	var enumTypes:Null<Array<CompilerType>> = null;

	/** Each class instance with arguments, and each map, in the order the walk for generic owners meets it. */
	var owners:Null<Array<CompilerType>> = null;

	/** Structures and enum instances that still hold a type variable: registered once typing settles them. */
	var waitingStructures:Null<Array<CompilerType>> = null;

	var waitingEnums:Null<Array<CompilerType>> = null;

	/**
	 * Whether these are a function of the types alone, which a later build may keep: none of the types holds a type variable or an
	 * open structure, which typing settles later.
	 */
	public var settled(default, null) = true;

	function new() {}

	/**
	 * Adds what `type` gives all three registries to `uses`, made when `type` gives anything; for a declaration's types, whose uses
	 * are kept only when settled.
	 */
	public static function add(session:TypingSession, uses:Null<ProgramTypeUses>,
			type:CompilerType):Null<ProgramTypeUses> {
		if (Monomorphs.contains(type) || session.monomorphs.mentionsOpen(type)) {
			var into = uses ?? new ProgramTypeUses();
			uses = into;
			into.settled = false;
		}
		uses = addStructures(session, uses, reached(type));
		uses = addEnums(session, uses, type, null);
		// Owners are explored once per type.
		return addOwners(session, uses, type, []);
	}

	/** What `type`'s structures give the program, or null for nothing. */
	public static function structuresOf(session:TypingSession, type:CompilerType):Null<ProgramTypeUses>
		return addStructures(session, null, reached(type));

	/** The enum specializations `type` reaches, or null for none. */
	public static function enumsOf(session:TypingSession, type:CompilerType):Null<ProgramTypeUses>
		return addEnums(session, null, type, null);

	/** Marks the uses as made of `source`. */
	public function madeOf(source:Any):ProgramTypeUses {
		this.source = source;
		return this;
	}

	/** `--check-reuse`: whether `other`, made afresh of the same source, names what these do, in the same order. */
	public static function same(left:Null<ProgramTypeUses>, right:Null<ProgramTypeUses>):Bool {
		if (left == null || right == null)
			return left == right;
		return sameNames([for (structure in left.structures ?? []) structure.name],
			[for (structure in right.structures ?? []) structure.name])
			&& sameNames(left.enumNames ?? [], right.enumNames ?? [])
			&& sameNames([for (type in left.owners ?? []) compiler.semantic.SemanticSignature.type(type)],
			[for (type in right.owners ?? []) compiler.semantic.SemanticSignature.type(type)]);
	}

	static function sameNames(left:Array<String>, right:Array<String>):Bool {
		if (left.length != right.length)
			return false;
		for (index in 0...left.length)
			if (left[index] != right[index])
				return false;
		return true;
	}

	/** Registers all of the uses with `session`; `origin` is what a map's owner is recorded as a runtime dependency of. */
	public function register(session:TypingSession, origin:Null<String>):Void {
		registerStructures(session);
		registerEnums(session);
		var owners = this.owners;
		if (owners != null)
			for (type in owners)
				switch type {
					case TMap(key, value):
						var owner = session.mapOwner(key, value);
						if (owner != null) {
							if (origin != null)
								session.runtimeDependencyTracker.record(origin, owner);
							session.representation.specializedMapOwner(owner, key, value);
						}
					default:
						session.representation.genericOwner(type);
				}
	}

	/** Gives the program each of the structures it does not have yet. */
	public function registerStructures(session:TypingSession):Void {
		var structures = this.structures, waiting = waitingStructures;
		if (structures != null)
			for (structure in structures)
				addStructure(session, structure.name, structure.fields);
		if (waiting != null)
			for (type in waiting)
				session.monomorphs.whenKnown(type, () -> {
					var settled = structuresOf(session, session.monomorphs.settled(type));
					if (settled != null)
						settled.registerStructures(session);
				});
	}

	/** Gives the program structure `name`, unless it has it: what it keeps is made outside the arena of the unit that met it. */
	public static function addStructure(session:TypingSession, name:String, fields:Array<AnonymousField>):Void
		if (!session.anonymousTypes.exists(name))
			session.anonymousTypes.set(compiler.core.GlobalNames.of(name), compiler.core.Arena.toGlobal(fields));

	/** Asks for each of the enum specializations. */
	public function registerEnums(session:TypingSession):Void {
		var names = enumNames, types = enumTypes, waiting = waitingEnums;
		if (names != null && types != null)
			for (index in 0...names.length)
				session.output.discoverEnum(names[index], types[index]);
		if (waiting != null)
			for (type in waiting)
				session.monomorphs.whenKnown(type, () -> {
					var settled = enumsOf(session, session.monomorphs.settled(type));
					if (settled != null)
						settled.registerEnums(session);
				});
	}

	/** `type` with a type variable already filled replaced by its type, so a structure is registered under its final name. */
	static function reached(type:CompilerType):CompilerType
		return Monomorphs.contains(type) && !Monomorphs.containsUnbound(type) ? Monomorphs.resolve(type) : type;

	static function addStructures(session:TypingSession, uses:Null<ProgramTypeUses>,
			type:CompilerType):Null<ProgramTypeUses>
		return switch type {
			// An open literal structure is registered when it is closed, under its final name (`MonomorphFrames`).
			case TAnonymous(name, _) if (Monomorphs.isOpenStructureName(name)): uses;
			// A structure that mentions a type variable is named after its fields once they are known (`Monomorphs.resolve`).
			case TAnonymous(_, _) if (Monomorphs.containsUnbound(type)):
				var into = uses ?? new ProgramTypeUses();
				uses = into;
				into.waitingStructures = pushed(into.waitingStructures, type);
				uses;
			case TAnonymous(name, fields):
				var into = uses ?? new ProgramTypeUses();
				uses = into;
				if (into.addStructureUse(name, fields))
					for (field in fields)
						uses = addStructures(session, uses, field.type);
				uses;
			case TNullable(element), TArray(element), TIterator(element): addStructures(session, uses, element);
			case TKeyPath(root, value, _):
				var into = uses ?? new ProgramTypeUses();
				uses = into;
				into.addStructureUse(compiler.types.KeyPathType.descriptorName(root, value),
					compiler.types.KeyPathType.fields(root, value));
				addStructures(session, addStructures(session, uses, root), value);
			case TMap(key, value): addStructures(session, addStructures(session, uses, key), value);
			case TFunction(arguments, result, _):
				for (argument in arguments)
					uses = addStructures(session, uses, argument);
				addStructures(session, uses, result);
			default: uses;
		};

	function addStructureUse(name:String, fields:Array<AnonymousField>):Bool {
		var names = structureNames;
		if (names == null) {
			names = [];
			structureNames = names;
		}
		if (names.exists(name))
			return false;
		names.set(name, true);
		structures = pushed(structures, {name: name, fields: fields});
		return true;
	}

	static function addEnums(session:TypingSession, uses:Null<ProgramTypeUses>, type:CompilerType,
			seen:Null<Array<Array<AnonymousField>>>):Null<ProgramTypeUses>
		return switch type {
			case TInstance(NominalKind.Enum, _, arguments) if (arguments.length > 0):
				// An argument a type variable or an open literal structure still holds open is known when the body is typed (`Some(null)`,
				// `None`, `Some({a: 1})`).
				if (Monomorphs.containsUnbound(type) || session.monomorphs.mentionsOpen(type)) {
					var into = uses ?? new ProgramTypeUses();
					uses = into;
					into.waitingEnums = pushed(into.waitingEnums, type);
				} else {
					var resolved = Monomorphs.resolve(type);
					if (!session.representation.containsTypeParameter(resolved, [])) {
						var into = uses ?? new ProgramTypeUses();
						uses = into;
						into.enumNames = pushed(into.enumNames, EnumRuntimeType.name(resolved));
						into.enumTypes = pushed(into.enumTypes, resolved);
					}
				}
				uses;
			// Arguments contribute to identity, not necessarily storage. The instantiated payloads are discovered when the
			// specialization's declaration is registered.
			case TInstance(_, _, _): uses;
			case TAbstract(_, _, representation): addEnums(session, uses, representation, seen);
			case TNullable(element), TArray(element), TIterator(element): addEnums(session, uses, element, seen);
			case TMap(key, value),
				TKeyPath(key, value, _): addEnums(session, addEnums(session, uses, key, seen), value, seen);
			case TFunction(arguments, result, _):
				for (argument in arguments)
					uses = addEnums(session, uses, argument, seen);
				addEnums(session, uses, result, seen);
			case TAnonymous(_, fields):
				var within = seen == null ? [] : seen;
				if (within.indexOf(fields) < 0) {
					within.push(fields);
					for (field in fields)
						uses = addEnums(session, uses, field.type, within);
					within.pop();
				}
				uses;
			default: uses;
		};

	static function addOwners(session:TypingSession, uses:Null<ProgramTypeUses>, type:CompilerType,
			explored:Array<Array<AnonymousField>>):Null<ProgramTypeUses>
		return switch type {
			case TInstance(kind, _, arguments):
				if (kind == NominalKind.Class && arguments.length > 0) {
					var into = uses ?? new ProgramTypeUses();
					uses = into;
					into.owners = pushed(into.owners, type);
				}
				for (argument in arguments)
					uses = addOwners(session, uses, argument, explored);
				uses;
			case TAbstract(_, arguments, representation):
				for (argument in arguments)
					uses = addOwners(session, uses, argument, explored);
				addOwners(session, uses, representation, explored);
			case TNullable(inner), TArray(inner), TIterator(inner): addOwners(session, uses, inner, explored);
			case TMap(key, value):
				var into = uses ?? new ProgramTypeUses();
				uses = into;
				into.owners = pushed(into.owners, type);
				addOwners(session, addOwners(session, uses, key, explored), value, explored);
			case TKeyPath(root, value, _): addOwners(session, addOwners(session, uses, root, explored), value,
				explored);
			case TFunction(arguments, result, _):
				for (argument in arguments)
					uses = addOwners(session, uses, argument, explored);
				addOwners(session, uses, result, explored);
			case TAnonymous(_, fields):
				if (explored.indexOf(fields) < 0) {
					explored.push(fields);
					for (field in fields)
						uses = addOwners(session, uses, field.type, explored);
				}
				uses;
			default: uses;
		};

	static function pushed<T>(list:Null<Array<T>>, value:T):Array<T> {
		var result = list == null ? [] : list;
		result.push(value);
		return result;
	}
}
