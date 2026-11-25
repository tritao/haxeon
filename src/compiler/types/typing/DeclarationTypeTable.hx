package compiler.types.typing;

import compiler.core.DiagnosticCode;
import compiler.core.InternalError;
import compiler.core.Diagnostic;
import compiler.core.Diagnostic.CompileError;
import compiler.core.Source.SourceSpan;
import compiler.semantic.SemanticProgram;
import compiler.syntax.Ast.AstClass;
import compiler.syntax.Ast.AstExpression;
import compiler.syntax.Ast.AstField;
import compiler.syntax.Ast.AstFunction;
import compiler.syntax.AstFunctions;
import compiler.types.DeclarationTypes;
import compiler.types.Type.CompilerType;
import compiler.types.TypedAst.TypedExpression;
import compiler.types.TypedAst.TypedFunction;
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

/** An unannotated function's body typed for its signature (`DeclarationTyping.typeInferredFunction`). */
typedef InferredFunction = {
	final typed:TypedFunction;

	/** Whether the typing is the one the function's own slot keeps; otherwise only its signature is, and its output is dropped. */
	final kept:Bool;
}

/**
 * What typing an unannotated function's body for its signature passes between the table and `BodyTyper.typeFunction`: the
 * provisional signature a read of the function gets while its body is typed (its type variables, of the body's own frame), and the
 * signature once that frame is settled.
 */
class FunctionInference {
	final onProvisional:InferredSignature->Void;

	/** The settled signature, set when the body has been typed. */
	public var signature(default, null):Null<InferredSignature> = null;

	public function new(onProvisional:InferredSignature->Void)
		this.onProvisional = onProvisional;

	public function provisional(signature:InferredSignature):Void
		onProvisional(signature);

	public function settle(signature:InferredSignature):Void
		this.signature = signature;
}

/** A function whose signature its body gave, typed in its own unit, as its slot takes it (`DeclarationTypeTable.functionUnit`). */
typedef FunctionUnit = {
	final signature:InferredSignature;

	/** The typed function, or null when its typing failed (its error is recorded). */
	final typed:Null<TypedFunction>;

	/** What typing the unit produced, merged at the function's own place in declaration order; null when it failed. */
	final output:Null<TypingOutput>;
}

/** How the table types an unannotated declaration's initializer or body: the typer's side of the query. */
interface DeclarationTyping {
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

	/**
	 * Types the body of the unannotated function `fn` (key `key`) within the unit begun for it, giving `inference` its provisional
	 * and then its settled signature: as its own slot types it, when this build types it there (`kept`), or otherwise with its own and
	 * its owner's type parameters, for the signature alone (a generic function, a generic class's method, an abstract's instance
	 * method, or one this build does not type again and no earlier build gave a signature).
	 */
	function typeInferredFunction(fn:AstFunction, key:String, inference:FunctionInference):InferredFunction;
}

/** Where an unannotated function's signature stands; see `FieldState`. */
private enum FunctionState {
	/** Its body is being typed; a read of the function from its own body gets `provisional` (null before it exists). */
	InProgress(provisional:Null<InferredSignature>);

	/** Typed, with the unit kept for the function's own slot. */
	Typed(unit:FunctionUnit);

	/** Known without a unit of this build: typed by an earlier build (`seedFunction`), or for the signature alone. */
	Known(signature:InferredSignature);

	/** Its body failed, or it is in a cycle: reported once, by its own unit, and Dynamic to every reader where unannotated. */
	Failed;
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
 * An unannotated declaration's type is its initializer's or body's, typed the first time anything needs it, in its own unit (a
 * field's `InitializerUnit`, a function's own body) with its own type-variable frame, whose settling makes the type final. The
 * typing is kept: the unit's output is merged at the declaration's own place in declaration order when `ProgramTyper` reaches it
 * (`fieldInitializer`, `functionUnit`), whoever forced it. A declaration whose typing fails, or that is in a cycle of declarations
 * each needing the next one's type, is Dynamic to its readers where unannotated, with one diagnostic.
 *
 * Each declaration has a stable key, the name the program's signature table gives it: `Owner.member` for a field or method, the
 * function's name for a module function. Entries and the reads recorded for invalidation use it, never an AST node's identity,
 * since a warm session replaces the AST of an edited module.
 */
class DeclarationTypeTable implements DeclarationTypes {
	final declared:DeclaredTypes;
	final keys = new ObjectMap<AstFunction, String>();
	final session:Null<TypingSession>;
	final typing:Null<DeclarationTyping>;
	final program:compiler.syntax.Ast.AstProgram;
	final classes:compiler.semantic.DeclarationTable<AstClass>;

	/** The unannotated fields typed, being typed, failed or known, by key. */
	final fields:Map<String, FieldState> = [];

	/** The unannotated functions typed, being typed, failed or known, by key. */
	final functions:Map<String, FunctionState> = [];

	/** The keys of the declarations whose initializers or bodies are being typed, outermost first. */
	final forcing:Array<String> = [];

	/** The declarations found in a cycle: whatever their typing gives once the cycle is reported, they are failed. */
	final inCycle:Map<String, Bool> = [];

	/** Each declaration's place in declaration order, built the first time a cycle is reported. */
	var declarationOrder:Null<Map<String, Int>> = null;

	/**
	 * The type of an unannotated argument's default value, which the body typer gives; null in a session no body typer binds, where
	 * such an argument is Dynamic.
	 */
	final defaultValueType:Null<AstExpression->Null<CompilerType>>;

	/**
	 * The keys of the functions whose signature the source leaves, in part, to their bodies (a result or an argument without a
	 * type), by function: the only signatures typed here, and the only signature reads that are recorded. A map of its own keeps the lookup on
	 * every signature read small.
	 */
	final inferredKeys = new ObjectMap<AstFunction, String>();

	/** The function each inferred key names, for its span in a cycle diagnostic. */
	final inferredFunctions:Map<String, AstFunction> = [];

	/** The functions whose signature an earlier build gave (`seedFunctions`), until `--check-reuse` has typed them again. */
	final seeded:Map<String, Bool> = [];

	/** Whether a seeded signature is checked against its body typed again, on its first read (`--check-reuse`). */
	var checkingSeeds = false;

	public function new(declared:DeclaredTypes, semantic:SemanticProgram,
			defaultValueType:Null<AstExpression->Null<CompilerType>>, ?session:TypingSession,
			?typing:DeclarationTyping) {
		this.declared = declared;
		this.defaultValueType = defaultValueType;
		this.session = session;
		this.typing = typing;
		this.program = semantic.program;
		this.classes = semantic.declarations.classes;
		for (name => fn in semantic.signatures)
			keys.set(fn, name);
		// The signature table holds an abstract's methods with the owner's type parameters added, and no enum methods.
		for (decl in semantic.program.abstracts)
			for (method in decl.methods)
				keys.set(method, decl.name + "." + method.name);
		for (decl in semantic.program.enums)
			if (decl.methods != null)
				for (method in decl.methods)
					keys.set(method, decl.name + "." + method.name);
		// A class's methods as its declaration holds them: a reader that found one there reads its signature through here.
		for (decl in semantic.program.classes)
			for (method in decl.methods)
				if (!keys.exists(method))
					keys.set(method, decl.name + "." + method.name);
		// What the source leaves to a body: of a module function, a class's method or an abstract's, as the signature table holds
		// it (which a reused semantic program gives the new bodies) and as the program declares it. An interface's method has no
		// body to give it.
		var interfaces = [for (decl in semantic.program.interfaces) decl.name => true];
		for (name => fn in semantic.signatures) {
			var info = semantic.methodInfo.get(name);
			if (info == null || !interfaces.exists(info.owner))
				markInferred(fn, name);
		}
		for (fn in semantic.program.functions)
			markInferred(fn, fn.name);
		for (decl in semantic.program.classes)
			for (method in decl.methods)
				markInferred(method, decl.name + "." + method.name);
		for (decl in semantic.program.abstracts)
			for (method in decl.methods)
				markInferred(method, decl.name + "." + method.name);
	}

	/**
	 * Records that the unit being typed read the signature of `fn`: a class's members name its methods but leave their signatures
	 * to facts of their own, which the code that resolves a method's types reads here.
	 */
	inline function readSignatureOf(fn:AstFunction):Void {
		var typingSession = session;
		if (typingSession != null) {
			var key = keys.get(fn);
			if (key != null)
				typingSession.readSignature(key);
		}
	}

	/** Marks `fn` inferred when its source leaves a part of its signature (its result or an argument's type) to its body. */
	function markInferred(fn:AstFunction, key:String):Void
		if (AstFunctions.leavesSignatureToInference(fn)) {
			inferredKeys.set(fn, key);
			if (!inferredFunctions.exists(key))
				inferredFunctions.set(key, fn);
		}

	/**
	 * Makes `copy`, a function rewritten from the declaration `original` with the same arguments and result (an abstract's
	 * constructor as a construction inlines it), read the original's signature.
	 */
	public function alias(copy:AstFunction, original:AstFunction):Void {
		var key = keys.get(original);
		if (key == null)
			return;
		keys.set(copy, key);
		var inferred = inferredKeys.get(original);
		if (inferred != null)
			inferredKeys.set(copy, inferred);
	}

	/** The stable key of the declaration `fn` is, or null for a function no declaration holds (a closure, a specialization). */
	public function functionKey(fn:AstFunction):Null<String>
		return keys.get(fn);

	/** Whether `fn`'s signature is left, in part, to its body: then this table types it (`functionUnit`). */
	public function isInferred(fn:AstFunction):Bool
		return inferredKeys.exists(fn);

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
		// An inline constant's type is its value's, typed as a shared unit of its own (`InlineConstantResolver`).
		if (session != null)
			session.readUnit(field.isInline
				? TypingSession.INLINE_CONSTANT_PREFIX + key : compiler.semantic.InitializerUnit.of(owner,
				field.name));
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
	public static function substitute(type:CompilerType, substitutions:Null<Map<String, CompilerType>>):CompilerType
		return substitutions == null
			|| compiler.types.DeclarationIndex.isEmpty(substitutions) ? type : substituteWithin(type,
			substitutions);

	static function substituteWithin(type:CompilerType, substitutions:Map<String, CompilerType>):CompilerType
		return switch type {
			case TTypeParameter(_, name):
				var replacement = substitutions.get(name);
				replacement == null ? type : replacement;
			case TNullable(element): TNullable(substituteWithin(element, substitutions));
			case TArray(element): TArray(substituteWithin(element, substitutions));
			case TIterator(element): TIterator(substituteWithin(element, substitutions));
			case TMap(key, value): TMap(substituteWithin(key, substitutions), substituteWithin(value, substitutions));
			case TKeyPath(root, value, writable):
				TKeyPath(substituteWithin(root, substitutions), substituteWithin(value, substitutions), writable);
			case TFunction(arguments, result, optional): TFunction(substituteEach(arguments, substitutions),
				substituteWithin(result, substitutions), optional);
			case TInstance(kind, name, arguments): TInstance(kind, name, substituteEach(arguments, substitutions));
			case TAbstract(name, arguments, representation):
				TAbstract(name, substituteEach(arguments, substitutions),
					substituteWithin(representation, substitutions));
			default: type;
		};

	static function substituteEach(types:Array<CompilerType>,
			substitutions:Map<String, CompilerType>):Array<CompilerType>
		return [for (part in types) substituteWithin(part, substitutions)];

	/** Gives the unannotated field `key` of a class this build does not type again the type an earlier build gave it. */
	public function seedField(key:String, type:CompilerType):Void
		if (!fields.exists(key))
			fields.set(key, Known(type));

	/**
	 * Gives the unannotated functions this build does not type again the signatures an earlier build gave them
	 * (`ModuleState.inferredSignatures`): each is unchanged and, by the invalidation rule, so is every type its body read
	 * (docs/design/LAZY_DECLARATION_TYPING.md, "Warm builds: reused declarations"). An entry for a key that is no inferred function
	 * of this program (since annotated or removed) is not used. With `check` (`--check-reuse`), the first read of a seeded signature
	 * types the body again and fails, naming the function, when the signature differs.
	 */
	public function seedFunctions(previous:Map<String, InferredSignature>, selected:Map<String, Bool>,
			check:Bool):Void {
		checkingSeeds = check;
		for (key => signature in previous) {
			var fn = inferredFunctions.get(key);
			if (fn == null || selected.exists(key) || functions.exists(key))
				continue;
			if (!hasShapeOf(fn, signature))
				throw new InternalError('Function "$key" is seeded with a signature of another shape: its source changed, but it was not selected');
			functions.set(key, Known(signature));
			seeded.set(key, true);
		}
	}

	/** Whether `signature` has an entry exactly where `fn` leaves its signature to its body. */
	static function hasShapeOf(fn:AstFunction, signature:InferredSignature):Bool {
		if (signature.arguments.length != fn.arguments.length
			|| (signature.result != null) != AstFunctions.isInferred(fn.result))
			return false;
		for (index in 0...fn.arguments.length)
			if ((signature.arguments[index] != null) != AstFunctions.isInferred(fn.arguments[index].type))
				return false;
		return true;
	}

	/** The types of the unannotated fields typed or known so far, by key; not those that failed. */
	public function knownFieldTypes():Map<String, CompilerType> {
		var result:Map<String, CompilerType> = [];
		for (key => state in fields)
			switch state {
				case Typed(unit): result.set(key, unit.type);
				case Known(type): result.set(key, type);
				case InProgress(_), Failed:
			}
		return result;
	}

	/**
	 * The signatures of the unannotated functions whose bodies this build typed, by key, which the next build seeds the ones it does
	 * not type again with; not the seeded ones, nor those that failed.
	 */
	public function typedSignatures():Map<String, InferredSignature> {
		var result:Map<String, InferredSignature> = [];
		for (key => state in functions)
			if (!seeded.exists(key))
				switch state {
					case Typed(unit): result.set(key, unit.signature);
					case Known(signature): result.set(key, signature);
					case InProgress(_), Failed:
				}
		return result;
	}

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
			case state: throw new InternalError('Field "$key" reaches its slot as $state');
		};
	}

	function force(owner:String, field:AstField, key:String):CompilerType {
		var classDecl = classes.get(owner);
		if (typing == null || session == null || classDecl == null || field.initializer == null)
			throw new InternalError('Unannotated field "$key" has no initializer the typer can type');
		if (field.isInline) {
			// An inline constant is typed once, on demand, by its own resolver, which reports its cycles.
			var type = requiredTyping().inlineFieldType(classDecl, field);
			fields.set(key, Known(type));
			return type;
		}
		fields.set(key, InProgress(null));
		forcing.push(key);
		var unit = try typeUnit(classDecl, field, null) catch (error:haxe.Exception) {
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
	 * checkpoint to return to if it fails, which records its error once. A cycle found inside it is passed on to the declaration it
	 * was found on, which recovers from it for all the cycle's members.
	 */
	function typeUnit(owner:AstClass, field:AstField, type:Null<CompilerType>):FieldInitializerUnit {
		var typing = requiredTyping(),
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
	 * The argument types of `fn` as callers see them. Argument and result reads are recorded under the same key: before typing, the
	 * coarse rule of slice 2 cannot tell which part of an inferred signature an edit changed.
	 */
	public function argumentTypes(fn:AstFunction, ?substitutions:Map<String, CompilerType>):Array<CompilerType> {
		readSignatureOf(fn);
		var key = inferredKeys.get(fn);
		if (key == null)
			return [
				for (argument in fn.arguments)
					declared.argumentType(argument, substitutions,
					DeclaredTypes.typedByDefault(argument)
					&& defaultValueType != null ? defaultValueType(argument.defaultValue) : null)
			];
		if (session != null)
			session.readUnit(key);
		var signature = functionSignature(fn, key);
		return [for (index in 0...fn.arguments.length) {
			var argument = fn.arguments[index],
				inferred = signature == null ? null : signature.arguments[index];
			if (inferred != null) substitute(inferred, substitutions);
			else if (AstFunctions.isInferred(argument.type))
				failedArgumentType(argument);
			else declared.argumentType(argument, substitutions, null);
		}];
	}

	/**
	 * The type the body of `fn` gave its unannotated argument `index`, in the function's own and its owner's type parameters, not
	 * substituted: what a call infers those parameters from, as it does from an annotation. Null where the argument is annotated, or
	 * the body failed.
	 */
	public function inferredArgumentType(fn:AstFunction, index:Int):Null<CompilerType> {
		var key = inferredKeys.get(fn);
		if (key == null)
			return null;
		if (session != null)
			session.readUnit(key);
		var signature = functionSignature(fn, key);
		return signature == null ? null : signature.arguments[index];
	}

	public function resultType(fn:AstFunction, ?substitutions:Map<String, CompilerType>):CompilerType {
		readSignatureOf(fn);
		var key = inferredKeys.get(fn);
		if (key == null)
			return declared.resultType(fn, substitutions);
		if (session != null)
			session.readUnit(key);
		if (!AstFunctions.isInferred(fn.result))
			return declared.resultType(fn, substitutions);
		var signature = functionSignature(fn, key), result = signature == null ? null : signature.result;
		return result == null ? TDynamic : substitute(result, substitutions);
	}

	/** An unannotated argument of a function whose body failed: Dynamic, nullable when the argument is optional. */
	static function failedArgumentType(argument:compiler.syntax.Ast.AstArgument):CompilerType
		return compiler.syntax.AstPredicates.isNullableArgument(argument) ? TNullable(TDynamic) : TDynamic;

	/**
	 * The signature the body of the unannotated function `fn` gives it, typing the body now if nothing has read it yet; null when the
	 * body failed or is in a cycle. Read from its own body, it is the provisional signature, whose type variables the body fixes.
	 */
	function functionSignature(fn:AstFunction, key:String):Null<InferredSignature>
		return switch functions.get(key) {
			case Typed(unit): unit.signature;
			case Known(signature):
				if (checkingSeeds && seeded.exists(key))
					checkSeed(fn, key, signature);
				signature;
			case Failed: null;
			case InProgress(provisional):
				if (forcing[forcing.length - 1] != key) {
					cycle(key);
					null;
				} else {
					if (provisional == null)
						throw new InternalError('Function "$key" is read before its provisional signature exists');
					provisional;
				}
			case null:
				forceFunction(fn, key);
				functionSignature(fn, key);
		};

	/**
	 * `--check-reuse`: types the body of the seeded function `key` again, for its signature alone, and fails when the signature
	 * differs from `signature`, the one the earlier build gave it, which a reader of this build was about to be typed against.
	 */
	function checkSeed(fn:AstFunction, key:String, signature:InferredSignature):Void {
		seeded.remove(key);
		functions.remove(key);
		forceFunction(fn, key);
		var typed = switch functions.get(key) {
			case Known(fresh): fresh;
			case state: throw new InternalError('--check-reuse: the seeded function "$key" typed again as $state');
		};
		if (signatureDigest(typed) != signatureDigest(signature))
			throw new InternalError('--check-reuse: the signature an earlier build gave "$key", ${signatureDigest(signature)}, '
				+ 'differs from its body\'s, ${signatureDigest(typed)}');
	}

	static function signatureDigest(signature:InferredSignature):String
		return [
			for (argument in signature.arguments)
				argument == null ? "_" : compiler.semantic.SemanticSignature.type(argument)
		].join(",")
			+ "->" + (signature.result == null ? "_" : compiler.semantic.SemanticSignature.type(signature.result));

	/**
	 * The unannotated function `fn` typed in its own unit, for its slot in `ProgramTyper`, which calls this only where it types the
	 * function itself in this build: the unit the query typed it in, typed now if nothing has read its signature yet. Null when its
	 * typing failed (its error is recorded).
	 */
	public function functionUnit(fn:AstFunction):Null<FunctionUnit> {
		var key = inferredKeys.get(fn);
		if (key == null)
			throw new InternalError('Function "${fn.name}" leaves nothing of its signature to its body');
		if (!functions.exists(key))
			forceFunction(fn, key);
		return switch functions.get(key) {
			case Typed(unit): unit;
			case Failed: null;
			case state: throw new InternalError('Function "$key" reaches its slot as $state');
		};
	}

	/**
	 * Types the body of the unannotated function `fn` as a unit of its own, wherever its signature is first needed, as `typeUnit`
	 * types a field's initializer. The unit is kept for the function's slot, or dropped when the typing was for the signature alone.
	 */
	function forceFunction(fn:AstFunction, key:String):Void {
		var typing = requiredTyping(), typingSession = requiredSession();
		functions.set(key, InProgress(null));
		forcing.push(key);
		var mark = typingSession.checkpoint(),
			begun = typingSession.beginDeclarationUnit(),
			inference = new FunctionInference(signature -> functions.set(key, InProgress(signature)));
		var typed = try {
			var result = typing.typeInferredFunction(fn, key, inference);
			typingSession.endDeclarationUnit(begun);
			result;
		} catch (error:CompileError) {
			forcing.pop();
			functions.set(key, Failed);
			if (Std.isOfType(error, DeclarationCycle) && (cast error:DeclarationCycle).target != key)
				throw error;
			typingSession.recover(mark, error);
			return;
		} catch (error:haxe.Exception) {
			forcing.pop();
			functions.set(key, Failed);
			throw error;
		}
		forcing.pop();
		var signature = inference.signature;
		if (signature == null)
			throw new InternalError('Function "$key" was typed without settling its signature');
		if (inCycle.exists(key))
			functions.set(key, Failed);
		else if (typed.kept)
			functions.set(key, Typed({signature: signature, typed: typed.typed, output: begun.unit}));
		else
			functions.set(key, Known(signature));
	}

	/**
	 * Reports the cycle that reading `key`, whose initializer or body is being typed, closes: `key` and every declaration forced
	 * since need each other's type. The diagnostic is put on the member first in declaration order and follows the cycle from there,
	 * so it does not depend on which member was forced first; every member becomes failed.
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
			others = [for (index in 1...chain.length) '"${chain[index]}"'],
			function_ = inferredFunctions.get(chain[0]);
		throw new DeclarationCycle(key, new Diagnostic(DiagnosticCode.ASSIGNMENT_OR_BINDING,
			'${function_ == null ? "Field" : "Function"} "${chain[0]}" needs a type annotation: its type depends on ${others.join(" and ")}, which '
			+ (others.length == 1 ? "depends" : "depend") + ' on it; annotate one of them',
			function_ == null ? fieldSpan(chain[0]) : function_.span));
	}

	function fieldSpan(key:String):SourceSpan {
		var dot = key.lastIndexOf("."), owner = classes.get(key.substr(0, dot)), name = key.substr(dot + 1);
		if (owner != null)
			for (field in owner.fields)
				if (field.name == name)
					return field.span;
		throw new InternalError('Unknown field "$key"');
	}

	/**
	 * The order of the declarations a cycle can involve: each class's fields and methods in the order they are written, the classes
	 * in program order, then module functions and abstract methods.
	 */
	function requiredDeclarationOrder():Map<String, Int> {
		var order = declarationOrder;
		if (order == null) {
			order = [];
			var next = 0;
			for (classDecl in program.classes) {
				var members:Array<{key:String, start:Int}> = [for (field in classDecl.fields)
					{
						key: fieldKey(classDecl.name, field), start: field.span.start
					}];
				for (method in classDecl.methods)
					members.push({key: classDecl.name + "." + method.name, start: method.span.start});
				haxe.ds.ArraySort.sort(members, (left, right) -> left.start - right.start);
				for (member in members)
					if (!order.exists(member.key))
						order.set(member.key, next++);
			}
			for (fn in program.functions)
				if (!order.exists(fn.name))
					order.set(fn.name, next++);
			for (decl in program.abstracts)
				for (method in decl.methods)
					if (!order.exists(decl.name + "." + method.name))
						order.set(decl.name + "." + method.name, next++);
			declarationOrder = order;
		}
		return order;
	}

	static function requiredOrder(order:Map<String, Int>, key:String):Int {
		var index = order.get(key);
		if (index == null)
			throw new InternalError('Declaration "$key" is not declared');
		return index;
	}

	function requiredSession():TypingSession {
		var bound = session;
		if (bound == null)
			throw new InternalError("No typing session types declarations");
		return bound;
	}

	function requiredTyping():DeclarationTyping {
		var bound = typing;
		if (bound == null)
			throw new InternalError("No typer types declarations");
		return bound;
	}
}

/**
 * A cycle of unannotated declarations, each needing the next one's type, found while typing their initializers or bodies. It
 * unwinds the units of the members forced since `target`, the declaration whose read closed it, which records it once.
 */
class DeclarationCycle extends CompileError {
	public final target:String;

	public function new(target:String, diagnostic:Diagnostic) {
		super(diagnostic);
		this.target = target;
	}
}
