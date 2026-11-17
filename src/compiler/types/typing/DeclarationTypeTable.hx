package compiler.types.typing;

import compiler.core.Diagnostic;
import compiler.core.Diagnostic.CompileError;
import compiler.core.Source.SourceSpan;
import compiler.semantic.SemanticProgram;
import compiler.syntax.Ast.AstClass;
import compiler.syntax.Ast.AstExpression;
import compiler.syntax.Ast.AstField;
import compiler.syntax.Ast.AstFunction;
import compiler.types.DeclarationTypes;
import compiler.types.Type.CompilerType;
import compiler.types.TypedAst.TypedExpression;
import haxe.ds.ObjectMap;

/** A field's initializer typed in its own unit (`InitializerUnit`), as `DeclarationTypeTable.fieldInitializer` gives it to its slot. */
typedef FieldInitializerUnit = {
	/** The field's type: its annotation, or its initializer's; Dynamic for an unannotated field whose initializer failed. */
	final type:CompilerType;

	/** The typed initializer, or null when its typing failed (its error is recorded). */
	final initializer:Null<TypedExpression>;

	final warnings:Null<Array<Diagnostic>>;

	/** What typing the unit produced, merged at the field's own place in declaration order; null when it failed. */
	final output:Null<TypingOutput>;
}

/** How the table types a declared class's field initializer: the typer's side of the query. */
interface FieldInitializerTyping {
	/**
	 * Types `field`'s initializer in a body context of its own, within the unit begun for it: against `type`, or, unannotated
	 * (`type` null), giving the field its initializer's type, with `provisional` called with the type a read of the field itself
	 * gets meanwhile.
	 */
	function typeFieldInitializer(owner:AstClass, field:AstField, type:Null<CompilerType>,
			provisional:CompilerType->Void):{
				initializer:TypedExpression,
				warnings:Array<Diagnostic>,
				type:CompilerType
			};

	/** The type of the unannotated inline field `field`: its constant's (`InlineConstantResolver`), typed once on demand. */
	function inlineFieldType(owner:AstClass, field:AstField):CompilerType;
}

/** Where an unannotated field's type stands (docs/design/LAZY_DECLARATION_TYPING.md, "The query"). */
private enum FieldState {
	/** Its initializer is being typed; a read of the field from its own initializer gets `provisional` (null before it exists). */
	InProgress(provisional:Null<CompilerType>);

	/** Typed, with the unit kept for the field's own slot. */
	Typed(unit:FieldInitializerUnit);

	/** Known without a unit of this build: typed by an earlier build (`seedField`), or an inline constant's. */
	Known(type:CompilerType);

	/** Its initializer failed, or it is in a cycle: reported once, by its own unit, and Dynamic to every reader. */
	Failed;
}

/**
 * The typer's answer to DeclarationTypes, owned by the TypingSession program view and given to DeclarationIndex by
 * TypingSession.bindSemantic.
 *
 * An unannotated field's type is its initializer's, typed the first time anything needs it, in its own unit
 * (`InitializerUnit`) with its own type-variable frame, whose settling makes the type final. The typing is kept: the unit's
 * output is merged at the field's own place in declaration order when `ProgramTyper` reaches it (`fieldInitializer`), whoever
 * forced it. A field whose initializer fails, or that is in a cycle of fields each needing the next one's type, is Dynamic to its
 * readers, with one diagnostic. Unannotated functions keep the signatures SignatureInference gives them until slice 4.
 *
 * Each declaration has a stable key, the name the program's signature table gives it: `Owner.member` for a field or method, the
 * function's name for a module function. Entries and the reads recorded for invalidation use it, never an AST node's identity,
 * since a warm session replaces the AST of an edited module.
 */
class DeclarationTypeTable implements DeclarationTypes {
	final declared:DeclaredTypes;
	final keys = new ObjectMap<AstFunction, String>();
	final session:Null<TypingSession>;
	final initializers:Null<FieldInitializerTyping>;
	final program:compiler.syntax.Ast.AstProgram;
	final classes:Map<String, AstClass>;

	/** The unannotated fields typed, being typed, failed or known, by key. */
	final fields:Map<String, FieldState> = [];

	/** The keys of the fields whose initializers are being typed, outermost first. */
	final forcing:Array<String> = [];

	/** The fields found in a cycle: whatever their typing gives once the cycle is reported, they are failed. */
	final inCycle:Map<String, Bool> = [];

	/** Each field's place in declaration order, built the first time a cycle is reported. */
	var declarationOrder:Null<Map<String, Int>> = null;

	/**
	 * The type of an unannotated argument's default value, which the body typer gives until slice 4 types it here; null in a
	 * session no body typer binds, where such an argument is Dynamic.
	 */
	final defaultValueType:Null<AstExpression->Null<CompilerType>>;

	/**
	 * Records that the unit being typed read the inferred type of the declaration with this key, so that an edit that may change
	 * the type retypes the unit (`UnitRecords.declarationTypeReads`); null where nothing records.
	 */
	final recordRead:Null<String->Void>;

	/**
	 * The keys of the functions whose signature the source leaves to inference (`SemanticProgram.inferredSignatures`), by function:
	 * the only signature reads that are recorded. A map of its own keeps the lookup on every signature read small.
	 */
	final inferredKeys = new ObjectMap<AstFunction, String>();

	public function new(declared:DeclaredTypes, semantic:SemanticProgram,
			defaultValueType:Null<AstExpression->Null<CompilerType>>, ?recordRead:String->Void, ?session:TypingSession,
			?initializers:FieldInitializerTyping) {
		this.declared = declared;
		this.defaultValueType = defaultValueType;
		this.recordRead = recordRead;
		this.session = session;
		this.initializers = initializers;
		this.program = semantic.program;
		this.classes = semantic.declarations.classes;
		var inferred = semantic.inferredSignatures;
		for (name => fn in semantic.signatures)
			setKey(fn, name, inferred);
		// The signature table holds an abstract's methods with the owner's type parameters added, and no enum methods.
		for (decl in semantic.program.abstracts)
			for (method in decl.methods)
				setKey(method, decl.name + "." + method.name, inferred);
		for (decl in semantic.program.enums)
			if (decl.methods != null)
				for (method in decl.methods)
					setKey(method, decl.name + "." + method.name, inferred);
	}

	function setKey(fn:AstFunction, key:String, inferred:Map<String, Bool>):Void {
		keys.set(fn, key);
		if (inferred.exists(key))
			inferredKeys.set(fn, key);
	}

	/** The stable key of the declaration `fn` is, or null for a function no declaration holds (a closure, a specialization). */
	public function functionKey(fn:AstFunction):Null<String>
		return keys.get(fn);

	/** The stable key of `owner`'s field `field`. */
	public static function fieldKey(owner:String, field:AstField):String
		return owner + "." + field.name;

	/**
	 * An unannotated field's type is kept in its class's own type parameters (`TTypeParameter`), as an annotation resolves, and
	 * substituted for each reader.
	 */
	public function fieldType(owner:String, field:AstField, ?substitutions:Map<String, CompilerType>):CompilerType {
		if (field.type != null)
			return declared.fieldType(owner, field, substitutions);
		var key = fieldKey(owner, field);
		if (recordRead != null)
			recordRead(key);
		return switch fields.get(key) {
			case Typed(unit): substitute(unit.type, substitutions);
			case Known(type): substitute(type, substitutions);
			case Failed: TDynamic;
			case InProgress(provisional):
				// Read from its own initializer: the type variable the initializer's type fills, as Haxe gives a self-reference.
				if (forcing[forcing.length - 1] == key) provisional == null ? TDynamic : provisional;
				else cycle(key);
			case null: substitute(force(owner, field, key), substitutions);
		};
	}

	/**
	 * `type` with each type parameter `substitutions` names replaced. A field's type mentions one only inside the types that can
	 * hold it (`ProgramTyper.typeFieldInitializer` rejects a structure that would), so a structure is left as it is.
	 */
	public static function substitute(type:CompilerType, substitutions:Null<Map<String, CompilerType>>):CompilerType {
		if (substitutions == null)
			return type;
		function each(types:Array<CompilerType>):Array<CompilerType>
			return [for (part in types) substitute(part, substitutions)];
		return switch type {
			case TTypeParameter(_, name):
				var replacement = substitutions.get(name);
				replacement == null ? type : replacement;
			case TNullable(element): TNullable(substitute(element, substitutions));
			case TArray(element): TArray(substitute(element, substitutions));
			case TIterator(element): TIterator(substitute(element, substitutions));
			case TMap(key, value): TMap(substitute(key, substitutions), substitute(value, substitutions));
			case TKeyPath(root, value, writable):
				TKeyPath(substitute(root, substitutions), substitute(value, substitutions), writable);
			case TFunction(arguments, result, optional): TFunction(each(arguments), substitute(result, substitutions),
				optional);
			case TInstance(kind, name, arguments): TInstance(kind, name, each(arguments));
			case TAbstract(name, arguments, representation):
				TAbstract(name, each(arguments), substitute(representation, substitutions));
			default: type;
		};
	}

	/** Gives the unannotated field `key` of a class this build does not type again the type an earlier build gave it. */
	public function seedField(key:String, type:CompilerType):Void
		if (!fields.exists(key))
			fields.set(key, Known(type));

	/**
	 * `field`'s initializer typed in its own unit, for its slot in `ProgramTyper.typeClass`: typed now when it is annotated (with
	 * type `type`); for an unannotated field the unit the query typed it in, typed now if nothing has read its type yet.
	 */
	public function fieldInitializer(owner:AstClass, field:AstField, type:CompilerType):FieldInitializerUnit {
		if (field.type != null)
			return typeUnit(owner, field, type);
		var key = fieldKey(owner.name, field);
		if (!fields.exists(key))
			force(owner.name, field, key);
		return switch fields.get(key) {
			case Typed(unit): unit;
			case Failed: {
				type: TDynamic,
				initializer: null,
				warnings: null,
				output: null
			};
			case state: throw 'Field "$key" reaches its slot as $state';
		};
	}

	function force(owner:String, field:AstField, key:String):CompilerType {
		var classDecl = classes.get(owner);
		if (initializers == null || session == null || classDecl == null || field.initializer == null)
			throw 'Unannotated field "$key" has no initializer the typer can type';
		if (field.isInline) {
			// An inline constant is typed once, on demand, by its own resolver, which reports its cycles.
			var type = requiredInitializers().inlineFieldType(classDecl, field);
			fields.set(key, Known(type));
			return type;
		}
		fields.set(key, InProgress(null));
		forcing.push(key);
		var unit = try typeUnit(classDecl, field, null) catch (error:Dynamic) {
			forcing.pop();
			fields.set(key, Failed);
			throw error;
		}
		forcing.pop();
		if (unit.output == null || inCycle.exists(key)) {
			fields.set(key, Failed);
			return TDynamic;
		}
		fields.set(key, Typed(unit));
		return unit.type;
	}

	/**
	 * Types `field`'s initializer as a unit of its own, wherever it is first needed: a clean body context, frame and output, and a
	 * checkpoint to return to if it fails, which records its error once. A cycle found inside it is passed on to the field it was
	 * found on, which recovers from it for all the cycle's members.
	 */
	function typeUnit(owner:AstClass, field:AstField, type:Null<CompilerType>):FieldInitializerUnit {
		var typing = requiredInitializers(),
			typingSession = requiredSession(),
			key = fieldKey(owner.name, field),
			mark = typingSession.checkpoint(),
			begun = typingSession.beginDeclarationUnit();
		try {
			var typed = typing.typeFieldInitializer(owner, field, type,
				provisional -> fields.set(key, InProgress(provisional)));
			typingSession.endDeclarationUnit(begun);
			return {
				type: typed.type,
				initializer: typed.initializer,
				warnings: typed.warnings,
				output: begun.unit
			};
		} catch (error:CompileError) {
			if (Std.isOfType(error, DeclarationCycle) && (cast error:DeclarationCycle).target != key)
				throw error;
			typingSession.recover(mark, error);
			return {
				type: type == null ? TDynamic : type,
				initializer: null,
				warnings: null,
				output: null
			};
		}
	}

	/**
	 * Reports the cycle that reading `key`, whose initializer is being typed, closes: `key` and every field forced since need each
	 * other's type. The diagnostic is put on the member first in declaration order and follows the cycle from there, so it does not
	 * depend on which member was forced first; every member becomes failed.
	 */
	function cycle(key:String):CompilerType {
		var members = forcing.slice(forcing.indexOf(key));
		for (member in members)
			inCycle.set(member, true);
		var order = requiredDeclarationOrder(), first = 0;
		for (index in 1...members.length)
			if (requiredOrder(order, members[index]) < requiredOrder(order, members[first]))
				first = index;
		var chain = members.slice(first).concat(members.slice(0, first)),
			others = [for (index in 1...chain.length) '"${chain[index]}"'];
		throw new DeclarationCycle(key, new Diagnostic("E1002",
			'Field "${chain[0]}" needs a type annotation: its type depends on ${others.join(" and ")}, which '
			+ (others.length == 1 ? "depends" : "depend") + ' on it; annotate one of them', fieldSpan(chain[0])));
	}

	function fieldSpan(key:String):SourceSpan {
		var dot = key.lastIndexOf("."), owner = classes.get(key.substr(0, dot)), name = key.substr(dot + 1);
		if (owner != null)
			for (field in owner.fields)
				if (field.name == name)
					return field.span;
		throw 'Unknown field "$key"';
	}

	function requiredDeclarationOrder():Map<String, Int> {
		var order = declarationOrder;
		if (order == null) {
			order = [];
			var next = 0;
			for (classDecl in program.classes)
				for (field in classDecl.fields)
					order.set(fieldKey(classDecl.name, field), next++);
			declarationOrder = order;
		}
		return order;
	}

	static function requiredOrder(order:Map<String, Int>, key:String):Int {
		var index = order.get(key);
		if (index == null)
			throw 'Field "$key" is not declared';
		return index;
	}

	function requiredSession():TypingSession {
		var bound = session;
		if (bound == null)
			throw "No typing session types field initializers";
		return bound;
	}

	function requiredInitializers():FieldInitializerTyping {
		var bound = initializers;
		if (bound == null)
			throw "No typer types field initializers";
		return bound;
	}

	/**
	 * Argument and result reads are recorded under the same key: before typing, the coarse rule of slice 2 cannot tell which part
	 * of an inferred signature an edit changed.
	 */
	public function argumentTypes(fn:AstFunction, ?substitutions:Map<String, CompilerType>):Array<CompilerType> {
		recordSignatureRead(fn);
		return [
			for (argument in fn.arguments)
				declared.argumentType(argument, substitutions,
				DeclaredTypes.typedByDefault(argument)
				&& defaultValueType != null ? defaultValueType(argument.defaultValue) : null)
		];
	}

	public function resultType(fn:AstFunction, ?substitutions:Map<String, CompilerType>):CompilerType {
		recordSignatureRead(fn);
		return declared.resultType(fn, substitutions);
	}

	function recordSignatureRead(fn:AstFunction):Void {
		if (recordRead == null)
			return;
		var key = inferredKeys.get(fn);
		if (key != null)
			recordRead(key);
	}
}

/**
 * A cycle of unannotated fields, each needing the next one's type, found while typing their initializers. It unwinds the units
 * of the members forced since `target`, the field whose read closed it, which records it once.
 */
class DeclarationCycle extends CompileError {
	public final target:String;

	public function new(target:String, diagnostic:Diagnostic) {
		super(diagnostic);
		this.target = target;
	}
}
