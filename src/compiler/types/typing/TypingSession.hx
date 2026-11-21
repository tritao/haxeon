package compiler.types.typing;

import compiler.core.Diagnostic;
import compiler.core.InternalError;
import compiler.semantic.GenericSpecializationRegistry;
import compiler.semantic.SemanticProgram;
import compiler.semantic.SemanticProgram.SemanticMethodInfo;
import compiler.runtime.RuntimeType;
import compiler.syntax.Ast.AstFunction;
import compiler.types.analysis.ClosureConversion;
import compiler.types.Type.CompilerType;
import compiler.types.Type.NominalKind;
import compiler.types.TypedAst.TypedNativeLayout;
import compiler.core.Source.SourceSpan;
import compiler.types.analysis.Scope;

/** Where typing stood before a body: see `TypingSession.checkpoint`. */
typedef TypingCheckpoint = {
	final contexts:Int;
	final outputs:Int;
	final output:TypingOutput;
	final defaultArgumentDepth:Int;
	final monomorphs:Int;
	final lintFacts:compiler.types.typing.UnitRecords.LintFactCounts;
}

/**
 * The typing state of one compilation: the program view bodies are typed against (declarations, relations, signatures,
 * representations, the facts about purity and no-return functions) and the body context stack, plus where typing writes:
 * the output of the unit being typed (`output`), merged into the program's (`programOutput`) in declaration order.
 */
class TypingSession {
	public var signatures:Map<String, AstFunction> = [];

	public var methodInfo:Map<String, SemanticMethodInfo> = [];

	/** `signatures` and `methodInfo` by owner, then member name, as the program bound last has them. */
	public var signaturesByOwner:Map<String, Map<String, AstFunction>> = [];

	public var methodsByOwner:Map<String, Map<String, SemanticMethodInfo>> = [];

	/** The program's static extensions (`StaticExtensions`), from the program bound last. */
	public var staticExtensions:compiler.semantic.StaticExtensionTable = compiler.semantic.StaticExtensionTable.empty();
	public final externals:Map<String, {arguments:Array<CompilerType>, result:CompilerType}>;
	public var classDecls:Map<String, compiler.syntax.Ast.AstClass> = [];
	public var interfaceDecls:Map<String, compiler.syntax.Ast.AstInterface> = [];
	public var enumDecls:Map<String, compiler.syntax.Ast.AstEnum> = [];

	var enumsByFile:Null<Map<String, Array<{name:String, declaration:compiler.syntax.Ast.AstEnum}>>> = null;

	public final enumRepresentations:EnumRuntimeRepresentations;
	public var enumAbstractDecls:Map<String, compiler.syntax.Ast.AstAbstract> = [];

	/**
	 * The enum abstract a source name denotes, directly or through typedefs, or null. Every lookup of an enum abstract by a
	 * name written in source goes through this, so `typedef K = E;` reaches E's values, statics and conversions as E does.
	 */
	public function enumAbstractName(name:String):Null<String> {
		var resolved = declarations.enumAbstractQualifier(name);
		return resolved != null && enumAbstractDecls.exists(resolved) ? resolved : null;
	}
	public var declarations:DeclarationIndex;

	/** The declaration types of the program bound last (`bindSemantic`), which `declarations.types` answers with. */
	public var types(default, null):Null<DeclarationTypeTable> = null;

	public var relations:TypeRelations;

	/**
	 * The program's output: the bodies' outputs merged in declaration order, and what typing outside any unit produces. See
	 * `TypingOutput`.
	 */
	public final programOutput = new TypingOutput(false, 1);

	/** Where typing writes now: the output of the unit being typed, or the program's. */
	public var output(default, null):TypingOutput;

	final outputs:Array<TypingOutput> = [];

	/** The outputs of the shared units typed in a unit, by name, until they are merged. */
	final sharedOutputs:Map<String, TypingOutput> = [];

	final mergedUnits:Map<String, Bool> = [];

	/** The shared units typed inside an arena, by name, until the work that typed them copies their outputs out. */
	final sharedInArena:Array<String> = [];

	/** Closure conversion for the unit being typed. */
	public var closureConversion(get, never):ClosureConversion;

	inline function get_closureConversion():ClosureConversion
		return output.closureConversion;

	/** Starts typing a unit (a function body, or a class's fields and initializers) into its own output. */
	public function beginUnit():TypingOutput
		return pushUnit(new TypingOutput(false, bodyContexts.length));

	/**
	 * Starts typing a unit for its errors alone, into an output the caller drops: a body whose code is typed elsewhere (a generic
	 * abstract's member or a generic function, per specialization). A shared unit or a declaration's unit it types is the program's, as anywhere else.
	 */
	public function beginCheckUnit():TypingOutput
		return pushUnit(new TypingOutput(false, bodyContexts.length, true));

	function pushUnit(unit:TypingOutput):TypingOutput {
		outputs.push(output);
		output = unit;
		return unit;
	}

	/** The shared units typed inside an arena since the last call, with their outputs; the list starts over. */
	public function takeSharedInArena():Array<SharedUnit> {
		var units = [for (name in sharedInArena) new SharedUnit(name, sharedOutputs.get(name))];
		sharedInArena.resize(0);
		return units;
	}

	/** Puts the output of the shared unit `name` back, once copied out of the arena it was typed in. */
	public function replaceSharedOutput(name:String, output:TypingOutput):Void
		sharedOutputs.set(name, output);

	public function endUnit(unit:TypingOutput):Void {
		if (output != unit)
			throw new InternalError("Typing outputs must be left in stack order");
		output = outputs.pop();
	}

	/** Records that the code being typed uses the shared unit `name`: a generic function specialization, an inline constant. */
	public function useSharedUnit(name:String):Void
		if (output != programOutput)
			output.recordUse(name, bodyContexts.length < 2 ? null : anonymousUnit());

	/**
	 * Types the shared unit `name` with `type`, into an output of its own when a unit is being typed. Call `useSharedUnit` first:
	 * the shared unit's output is merged where its first user in declaration order used it, whichever body typed it. With
	 * `checkOnly`, the unit is typed for its errors alone (`beginCheckUnit`): a specialization for type parameters of a body
	 * being checked, which no program code can call. With `unused`, no code has used it yet, so it is typed into an output of its
	 * own even outside any unit: it is merged only if code uses it.
	 */
	public function typeSharedUnit(name:String, type:() -> Void, checkOnly:Bool = false, unused:Bool = false):Void {
		if (output == programOutput && !checkOnly && !unused) {
			type();
			return;
		}
		var unit = new TypingOutput(true, bodyContexts.length, checkOnly);
		sharedOutputs.set(name, unit);
		if (compiler.core.Arena.depth > 0)
			sharedInArena.push(name);
		outputs.push(output);
		output = unit;
		try {
			type();
		} catch (error:haxe.Exception) {
			endUnit(unit);
			throw error;
		}
		endUnit(unit);
	}

	/**
	 * The errors typing recovered from, in the order they were met: one per body (a function, a field initializer) whose typing
	 * failed. The program typer goes on with the next body, then fails with all of them (`failIfRecovered`).
	 */
	public final recoveredErrors:Array<Diagnostic> = [];

	/** Where typing stands between bodies, to come back to when the next one fails (`recover`). */
	public function checkpoint():TypingCheckpoint
		return {
			contexts: bodyContexts.length,
			outputs: outputs.length,
			output: output,
			defaultArgumentDepth: defaultArgumentDepth,
			monomorphs: monomorphs.depth(),
			lintFacts: output.records.lintFactCounts()
		};

	/**
	 * Records the errors of a body whose typing failed and returns to `mark`, taken before it: the body contexts, outputs and
	 * type-variable frames it left open are closed (its type variables become Dynamic, so none escapes), and its output, which the
	 * caller drops, is no longer written to. Only a `CompileError` is recovered from; anything else is a compiler bug and stops typing.
	 */
	public function recover(mark:TypingCheckpoint, error:CompileError):Void {
		rewind(mark);
		for (diagnostic in error.diagnostics)
			recordRecovered(diagnostic);
	}

	/**
	 * Returns to `mark`, taken before a body whose typing stopped, without recording why (`recover` records it): the body contexts,
	 * outputs and type-variable frames it left open are closed, and its output is no longer written to.
	 */
	public function rewind(mark:TypingCheckpoint):Void {
		monomorphs.discardFrom(mark.monomorphs);
		if (bodyContexts.length > mark.contexts)
			bodyContexts.splice(mark.contexts, bodyContexts.length - mark.contexts);
		if (outputs.length > mark.outputs)
			outputs.splice(mark.outputs, outputs.length - mark.outputs);
		output = mark.output;
		// A body typed in the output it returns to (a field initializer, in its class's) takes back the lint facts it recorded.
		output.records.truncateLintFacts(mark.lintFacts);
		defaultArgumentDepth = mark.defaultArgumentDepth;
	}

	function recordRecovered(diagnostic:Diagnostic):Void {
		// A shared unit (an inline constant) that fails is typed again, and fails again, in each body that uses it: report it once.
		for (existing in recoveredErrors)
			if (existing.code == diagnostic.code && existing.message == diagnostic.message
				&& existing.span.start == diagnostic.span.start && existing.span.end == diagnostic.span.end
				&& existing.span.file.path == diagnostic.span.file.path)
				return;
		recoveredErrors.push(diagnostic);
	}

	/**
	 * Fails with every recovered error, if typing recovered from any, and with `typed`, the functions that did type, and the types the
	 * table gave the unannotated declarations that typed.
	 */
	public function failIfRecovered(typed:Array<compiler.types.TypedAst.TypedFunction>):Void {
		if (recoveredErrors.length == 0)
			return;
		var table = types;
		throw new TypingFailure(recoveredErrors.copy(), typed, programOutput.records.unboundLocals.copy(),
			programOutput.records.nonExceptionThrows.copy(), table == null ? [] : table.knownFieldTypes(),
			table == null ? [] : table.typedSignatures());
	}

	/** `error`, with the errors recovered before it first: what a typing that stops at `error` fails with. */
	public function withRecovered(error:CompileError):CompileError {
		if (recoveredErrors.length == 0)
			return error;
		for (diagnostic in error.diagnostics)
			recordRecovered(diagnostic);
		return new CompileError(recoveredErrors[0], recoveredErrors.slice(1));
	}

	/**
	 * Merges the outputs of units typed in any order into the program's, in the order of `units` (declaration order), and
	 * registers the anonymous types of the shared units merged with them.
	 */
	public function mergeUnits(units:Array<TypingOutput>):Void {
		for (unit in units)
			unit.mergeInto(programOutput, sharedOutputs, mergedUnits, null);
		for (type in programOutput.takePendingAnonymousTypes())
			anonymousTypeRegistry.discover(type);
	}

	final anonymousTypeRegistry:AnonymousTypeRegistry;

	/**
	 * The unit the anonymous types used here belong to: the unit's outermost body, or null for the user of the shared unit being
	 * typed. A declaration's unit typed on demand begins inside the body that needed its type, and its outermost body is its own.
	 */
	function anonymousUnit():Null<String>
		return output.shared && output.baseDepth >= 2 ? null : bodyContexts[output.shared ? 1 : output.baseDepth].name;

	/** The type variables of the bodies being typed; see `Monomorphs`. */
	public final monomorphs:MonomorphFrames;

	/**
	 * Numbering of the names each body generates, and the lambdas typed so far: the unit's. A default argument is typed inside
	 * each caller, possibly in several units, so what its pseudo-body generates is numbered and cached program-wide, as one body.
	 */
	public var counters(get, never):BodyCounters;

	function get_counters():BodyCounters
		return defaultArgumentDepth > 0 ? programOutput.counters : output.counters;

	/** How many default argument pseudo-bodies (`$default:`) are open. */
	var defaultArgumentDepth = 0;

	/**
	 * Starts typing a declaration's own unit on demand (`DeclarationTypeTable`), wherever its type was first needed: a unit of its
	 * own, numbered by its own counters even inside a default argument's pseudo-body. Returns what `endDeclarationUnit` restores.
	 */
	public function beginDeclarationUnit():{unit:TypingOutput, defaultArgumentDepth:Int} {
		var suspended = defaultArgumentDepth;
		defaultArgumentDepth = 0;
		return {unit: beginUnit(), defaultArgumentDepth: suspended};
	}

	/** Ends the declaration unit `begun` and returns to the body that needed it. */
	public function endDeclarationUnit(begun:{unit:TypingOutput, defaultArgumentDepth:Int}):Void {
		endUnit(begun.unit);
		defaultArgumentDepth = begun.defaultArgumentDepth;
	}

	/** Passes the cached lambda typed at `key` through `map`, wherever it is cached. */
	public function mapCachedLambda(key:String, map:compiler.types.TypedTypeMap):Void {
		output.counters.mapLambda(key, map);
		if (output != programOutput)
			programOutput.counters.mapLambda(key, map);
	}

	/** Structural conversion helpers already emitted for each origin and target shape. */
	public final dynamicStructureConversions:Map<String, Bool> = [];


	public final bodyContexts:Array<TypingContext> = [outsideBodies()];

	/** The resolutions of what declarations hold outside their bodies (`SyntaxResolutions`). */
	public final syntaxResolutions = new SyntaxResolutions();

	/** The context outside every body, where constants and metadata are typed: no local is declared there. */
	static function outsideBodies():TypingContext {
		var context = new TypingContext("");
		context.resolution = compiler.types.analysis.BodyResolution.empty();
		return context;
	}

	/** Attributes an anonymous type to the unit being typed: the outermost body, which a lambda is part of. */
	public function recordAnonymousUse(name:String, fields:Array<compiler.types.Type.AnonymousField>):Void {
		if (bodyContexts.length >= 2)
			output.recordAnonymousUse(anonymousUnit(), name, fields);
	}

	public final anonymousTypes:Map<String, Array<compiler.types.Type.AnonymousField>> = [];
	public final genericSpecializations:GenericSpecializationRegistry;
	public final nativeAbiTarget:String;
	public final nativeLayoutsByName:Map<String, TypedNativeLayout> = [];
	public final emittedGenericBodies:Map<String, Bool> = [];
	public final noReturnFunctions:Map<String, Bool> = [];
	public final runtimeDependencyTracker = new RuntimeDependencyTracker();

	public final flagsMasks:Map<String, Int> = [];

	public final cNativeFunctions:Map<String, Bool> = [];

	/** Inline constants and enum abstract values resolved so far. */
	public final constants = new InlineConstantState();

	public final keyPaths = new KeyPathState();

	public final helperNames = new HelperNames();

	public final representation:TypeRepresentation;

	public var currentContext(get, never):TypingContext;

	inline function get_currentContext():TypingContext
		return bodyContexts[bodyContexts.length - 1];

	/** Helpers requested while checking defaults belong to the callee's real function, not its pseudo-body. */
	public function generatedFunctionOrigin():String {
		var name = currentContext.name;
		return StringTools.startsWith(name, DEFAULT_ARGUMENT_PREFIX)
			? name.substr(name.indexOf(DEFAULT_ARGUMENT_SEPARATOR) + 1) : name;
	}

	/** The name prefix of the pseudo-body a default argument value is typed in. */
	public static inline final DEFAULT_ARGUMENT_PREFIX = "$default:";

	static inline final DEFAULT_ARGUMENT_SEPARATOR = "|";

	/**
	 * The pseudo-body a default of `declaration` is typed in for `caller`. It is named after both, so what it numbers (its
	 * adapters, its lambdas) belongs to the caller's unit and does not depend on which other caller typed the default first.
	 */
	public static function defaultArgumentBody(caller:String, declaration:String):String
		return DEFAULT_ARGUMENT_PREFIX + caller + DEFAULT_ARGUMENT_SEPARATOR + declaration;

	public function new(externals:Null<Map<String, {arguments:Array<CompilerType>, result:CompilerType}>>,
			specializations:Null<GenericSpecializationRegistry>, ?nativeAbiTarget:String) {
		output = programOutput;
		this.externals = externals == null ? [] : externals;
		this.genericSpecializations = specializations == null ? new GenericSpecializationRegistry() : specializations;
		this.nativeAbiTarget = nativeAbiTarget == null ? "portable-abi64" : nativeAbiTarget;
		anonymousTypeRegistry = new AnonymousTypeRegistry(this);
		this.monomorphs = new MonomorphFrames(anonymousTypeRegistry.register);
		this.representation = new TypeRepresentation(this);
		this.enumRepresentations = new EnumRuntimeRepresentations(this);
	}

	var helperSpans:Map<String, SourceSpan> = [];
	final builtinHelperSpan:SourceSpan = SourceSpan.generated("value-equality");

	/** A shared generated implementation belongs to the type, independently of which caller requested it. */
	public function helperSpan(type:CompilerType, fallback:SourceSpan):SourceSpan {
		return switch type {
			case TNullable(element): helperSpan(element, fallback);
			case TInstance(_, name, _), TAbstract(name, _, _):
				var span = helperSpans.get(name);
				span == null ? builtinHelperSpan : span;
			// A structural type (an array, a map, an anonymous structure, a function) belongs to no declaration: its helper carries the
			// generated span, never the span of whichever caller asked first.
			case _: builtinHelperSpan;
		};
	}

	public function bindSemantic(semantic:SemanticProgram,
			?defaultValueType:compiler.syntax.Ast.AstExpression->Null<CompilerType>,
			?typing:DeclarationTypeTable.DeclarationTyping):Void {
		constants.clearEnumAbstractValues();
		flagsMasks.clear();
		for (declaration in semantic.program.enums)
			helperSpans.set(declaration.name, declaration.span);
		for (declaration in semantic.program.classes)
			helperSpans.set(declaration.name, declaration.span);
		for (declaration in semantic.program.abstracts)
			helperSpans.set(declaration.name, declaration.span);

		declarations = semantic.declarations;
		// Every reader of a declaration's type asks the program's table from here on.
		types = new DeclarationTypeTable(declarations.declaredTypes, semantic, defaultValueType,
			recordDeclarationTypeRead,
			this, typing);
		declarations.bindTypes(types);
		relations = semantic.relations;
		signatures = semantic.signatures;
		methodInfo = semantic.methodInfo;
		signaturesByOwner = semantic.signaturesByOwner;
		methodsByOwner = semantic.methodsByOwner;
		staticExtensions = semantic.staticExtensions;
		enumDecls = declarations.enums;
		enumsByFile = null;
		enumAbstractDecls = declarations.enumAbstracts;
	}

	/**
		The enums declared in the file at `path`. A bare case name resolves against its own file's enums, so this replaces
		a scan of every enum in the program for each identifier typed. `declarations.enums` is final, so the index lasts
		until the next `bindSemantic`.
	**/
	public function enumsInFile(path:String):Array<{name:String, declaration:compiler.syntax.Ast.AstEnum}> {
		var index = enumsByFile;
		if (index == null) {
			index = [];
			for (name => declaration in enumDecls) {
				var filePath = declaration.span.file.path,
					entries = index.get(filePath);
				if (entries == null) {
					entries = [];
					index.set(filePath, entries);
				}
				entries.push({name: name, declaration: declaration});
			}
			enumsByFile = index;
		}
		var found = index.get(path);
		return found == null ? noEnums : found;
	}

	@:processWide("a shared empty value, never added to")
	static final noEnums:Array<{
		name:String,
		declaration:compiler.syntax.Ast.AstEnum
	}> = [];

	public function bindNominalDeclarations():Void {
		interfaceDecls = declarations.interfaces;
		classDecls = declarations.classes;
	}

	/** `@:pure` on a function, or on the class of a static method, promises no observable writes.
	 * Calls to annotated or inferred-pure functions keep flow facts about captured locals, mutable fields and map entries.
	 *
	 * Records the answer against the function currently being typed: typed bodies are cached
	 * between incremental compiles, so a later compile whose fresh purity answer for `name`
	 * disagrees with what this body relied on must retype this body, even though its own source
	 * did not change. See `purityQueries` and the drift check in `SemanticAssembly`.
	 */
	public function isPureCall(name:String):Bool {
		var answer = inferredPureFunctions.exists(name) || isDeclaredPure(name);
		var caller = currentContext.name;
		if (caller != "")
			output.records.recordPurity(caller, name, answer);
		return answer;
	}

	/** Records that the body being typed read the inferred type of the declaration `key` (see `DeclarationTypeTable`). */
	public function recordDeclarationTypeRead(key:String):Void {
		var reader = currentContext.name;
		if (reader != "")
			output.records.recordDeclarationTypeRead(reader, key);
	}

	/** A value method can have global effects without writing its receiver. */
	public function isReadOnlyReceiver(name:String):Bool {
		var key = compiler.types.analysis.ReceiverMutationInference.PREFIX + name,
			answer = inferredPureFunctions.exists(key);
		var caller = currentContext.name;
		if (caller != "")
			output.records.recordPurity(caller, key, answer);
		return answer;
	}

	/** Whether writes through a binding may update the binding itself rather than a referenced object. */
	public function mayHoldValue(type:Null<compiler.syntax.Ast.AstType>,
			initializer:Null<compiler.syntax.Ast.AstExpression>):Bool {
		if (type != null && (switch (type) {
			case InferredType: false;
			default: true;
		})) {
			var resolved:Null<CompilerType> = null;
			try {
				resolved = declarations.resolve(type, null, currentContext.typeSubstitutions);
			} catch (_:compiler.core.Diagnostic.CompileError) {
				// The normal typing pass reports invalid or inferred annotations with the right source context.
				return true;
			}
			if (resolved == null)
				return true;
			return valueStorageType(resolved);
		}
		return switch initializer {
			case New(name, _,
				_) if (classDecls.exists(name)): relations.isValueClass(TInstance(NominalKind.Class, name, []));
			case ArrayLiteral(_, _), ObjectLiteral(_, _), Lambda(_, _, _, _): false;
			default: true;
		};
	}

	function valueStorageType(type:CompilerType):Bool
		return switch type {
			case TNullable(element), TAbstract(_, _, element): valueStorageType(element);
			case TInstance(NominalKind.Class, name, _): !classDecls.exists(name) || relations.isValueClass(type);
			case TDynamic, TTypeParameter(_, _), TInstance(NominalKind.NativeValue, _, _): true;
			default: false;
		};

	/** Storage analysis runs before expression typing; unknown receivers conservatively retain place writes. */
	public function mayBeKeyPath(type:Null<compiler.syntax.Ast.AstType>,
			initializer:Null<compiler.syntax.Ast.AstExpression>):Bool {
		if (type != null && (switch type {
			case InferredType: false;
			default: true;
		})) {
			try {
				return switch declarations.resolve(type, null, currentContext.typeSubstitutions) {
					case TKeyPath(_, _, _), TDynamic, TTypeParameter(_, _): true;
					default: false;
				};
			} catch (_:compiler.core.Diagnostic.CompileError)
				return true;
		}
		return switch initializer {
			case New(_, _, _), ArrayLiteral(_, _), ObjectLiteral(_, _), Lambda(_, _, _, _): false;
			default: true;
		};
	}

	/** The visible locals a closure can write, so a call can change: the innermost of each name. */
	public function closureWritableBindings(scope:Scope):Array<compiler.types.analysis.Scope.LocalBinding> {
		var storage = currentContext.storage;
		if (!storage.hasClosureWrites())
			return [];
		return [for (value in scope.visibleBindings()) if (storage.isClosureWrite(value.declaration)) value];
	}

	/** An impure call may invoke an escaped closure, including one forwarded through a named function. */
	public function invalidateUnknownCall(scope:Scope):Void {
		for (captured in closureWritableBindings(scope))
			scope.invalidateBinding(captured);
		scope.invalidateAllExpressions();
	}

	public function invalidateCallEffects(name:String, scope:Scope):Void {
		if (!isPureCall(name))
			invalidateUnknownCall(scope);
	}

	/** Annotated functions and read-only compiler intrinsics; the inference seeds from these. */
	function isDeclaredPure(name:String):Bool
		return compiler.types.analysis.PurityAnnotations.isDeclaredPure(name, signatures, classDecls);

	/** Static and module functions inferred pure by `PurityInference`. */
	public var inferredPureFunctions:Map<String, Bool> = [];

	var localPurity:Null<compiler.types.analysis.PurityInference> = null;

	/**
	 * Whether calling this local function can change state that flow facts describe. Its body is read like any other
	 * function's: no direct effects and only pure callees, judged against the answers this session already gives.
	 */
	public function localFunctionIsPure(local:compiler.types.analysis.Scope.LocalFunction, owner:Null<String>):Bool
		return bodyIsPure(local.arguments, local.body, local.outerLocals, owner);

	/** Whether running these statements can change state flow facts describe; `outerLocals` are locals it may freely write. */
	public function bodyIsPure(arguments:Array<compiler.syntax.Ast.AstArgument>,
			body:Array<compiler.syntax.Ast.AstStatement>, outerLocals:Array<String>,
			owner:Null<String>, ?privateMaps:Array<String>):Bool {
		var dependencies = compiler.types.analysis.PurityInference.localBodyDependencies(localPurityInference(),
			arguments, body,
			owner == null ? "$local" : owner + ".$local", outerLocals, privateMaps);
		return dependencies != null && dependenciesArePure(dependencies);
	}

	/**
		For a loop body: the fields it stores to and whether it stores to an element (array or map), when that is all
		it does to state anyone else can see; null when it may have any other effect.
	 */
	public function bodyStores(body:Array<compiler.syntax.Ast.AstStatement>, outerLocals:Array<String>,
			owner:Null<String>, ?privateMaps:Array<String>,
			?outerArrays:Array<String>, ?outerMaps:Array<String>):Null<{
				fields:Array<String>,
				indexed:Bool
			}> {
		var found = compiler.types.analysis.PurityInference.localBodyStores(localPurityInference(), body,
			owner == null ? "$local" : owner + ".$local",
			outerLocals, privateMaps, outerArrays, outerMaps);
		if (found == null || !dependenciesArePure(found.dependencies))
			return null;
		return {fields: found.fields, indexed: found.indexed};
	}

	function localPurityInference():compiler.types.analysis.PurityInference {
		var inference = localPurity;
		if (inference == null) {
			inference = compiler.types.analysis.PurityInference.create(signatures, classDecls, enumDecls,
				isDeclaredPure, isTypeName);
			localPurity = inference;
		}
		return inference;
	}

	function dependenciesArePure(dependencies:Array<String>):Bool {
		for (key in dependencies)
			// Typing a string conversion clears no facts either, so neither does depending on one.
			if (key != compiler.types.analysis.PurityInference.TO_STRING
				&& key != "Std.string"
				&& !(isPureCall(key) || isNoReturnCall(key)))
				return false;
		return true;
	}

	/** Takes the pure functions as already inferred, over the program this session types. */
	public function usePureFunctions(known:Map<String, Bool>):Void {
		localPurity = null;
		inferredPureFunctions = known;
	}

	public function inferPureFunctions():Void {
		localPurity = null;
		inferredPureFunctions = compiler.types.analysis.PurityInference.infer(signatures, classDecls,
			declarations.abstracts, enumDecls, isDeclaredPure,
			isTypeName);
	}

	function isTypeName(name:String):Bool
		return compiler.types.analysis.PurityAnnotations.isTypeName(name, classDecls, interfaceDecls, enumDecls,
			declarations.abstracts)
			|| enumAbstractName(name) != null;

	public function hasPureAnnotation(name:String):Bool
		return compiler.types.analysis.PurityAnnotations.hasPureAnnotation(name, signatures, classDecls);

	/** Whether a call to `name` was typed as never returning; recorded the same way as `isPureCall`. */
	public function isNoReturnCall(name:String):Bool {
		var answer = noReturnFunctions.exists(name);
		var caller = currentContext.name;
		if (caller != "")
			output.records.recordNoReturn(caller, name, answer);
		return answer;
	}

	/** Payload enum keys use their declared hash and equality in the ordinary specialized map. */
	public function mapName(key:CompilerType, value:CompilerType):Null<String> {
		var payloadKey = isPayloadEnumKey(key),
			hashable = DeclaredConformance.has(this, key, "Hashable");
		if (payloadKey && !hashable)
			return null;
		var builtin = payloadKey ? null : RuntimeType.mapName(key, value);
		if (builtin == null && !hashable)
			return null;
		if (requiresSpecializedMap(key, value)) {
			runtimeDependencyTracker.record(currentContext.name, RuntimeType.SPECIALIZED_MAP);
			representation.specializedMapOwner(key, value);
			return RuntimeType.SPECIALIZED_MAP;
		}
		return builtin;
	}

	public function isPayloadEnumKey(key:CompilerType):Bool {
		var info = enumKeyType(key);
		if (info == null)
			return false;
		var declaration = enumDecls.get(info.name);
		if (declaration == null)
			return false;
		for (constructor in declaration.cases)
			if (constructor.params.length > 0)
				return true;
		return false;
	}

	public function specializedMapKey(key:CompilerType):CompilerType
		return isPayloadEnumKey(key) ? key : RuntimeType.specializedMapKey(key);

	public function requiresSpecializedMap(key:CompilerType, value:CompilerType):Bool
		return isPayloadEnumKey(key)
			|| RuntimeType.usesSpecializedMap(key, value, mapValueType,
			type -> DeclaredConformance.has(this, type, "Hashable"));

	function mapValueType(type:CompilerType):Bool
		return switch type {
			case TAbstract(_, _, representation), TNullable(representation): mapValueType(representation);
			case TInstance(NominalKind.Class, _, _): relations.isValueClass(type);
			default: false;
		};

	static function enumKeyType(type:CompilerType):Null<{name:String, arguments:Array<CompilerType>}> {
		return switch type {
			case TAbstract(_, _, representation): enumKeyType(representation);
			case TInstance(NominalKind.Enum, name, arguments): {name: name, arguments: arguments};
			default: null;
		};
	}

	public function enterBody(name:String, ?typeSubstitutions:Map<String, CompilerType>, ?ownerOverride:String,
			?sourceFunctionName:String):TypingContext {
		var isLambda = compiler.semantic.LambdaName.is(name),
			owner = codeOwner(ownerOverride != null ? ownerOverride : isLambda
				? currentContext.lexicalOwner : parentPath(name)),
			source = sourceFunctionName != null ? sourceFunctionName : isLambda
				? currentContext.sourceFunctionName : null,
			body = new TypingContext(name, typeSubstitutions, owner, source);
		if (isLambda) {
			body.privateAccessDepth = currentContext.privateAccessDepth;
			body.memberInitializer = currentContext.memberInitializer;
			body.resolution = currentContext.resolution;
		}
		// A unit's outermost body: a top-level one, or a declaration's unit typed on demand inside another body.
		if (bodyContexts.length == 1 || !output.shared && bodyContexts.length == output.baseDepth)
			programOutput.records.typedUnits.set(name, true);
		if (StringTools.startsWith(name, DEFAULT_ARGUMENT_PREFIX))
			defaultArgumentDepth++;
		bodyContexts.push(body);
		return body;
	}

	/** Records a warning on the body being typed: the innermost one that is not a lambda, since a lambda is part of its function. */
	public function warn(diagnostic:Diagnostic):Void {
		var index = bodyContexts.length - 1;
		while (index > 0 && compiler.semantic.LambdaName.is(bodyContexts[index].name))
			index--;
		bodyContexts[index].warnings.push(diagnostic);
	}

	public function leaveBody(body:TypingContext):Void {
		if (currentContext != body)
			throw new InternalError("Body typing contexts must be left in stack order");
		bodyContexts.pop();
		if (StringTools.startsWith(body.name, DEFAULT_ARGUMENT_PREFIX))
			defaultArgumentDepth--;
	}

	/** The declaration whose code a body of `owner` is: an abstract's, for its statics' storage class (`AbstractStatics`). */
	static function codeOwner(owner:Null<String>):Null<String>
		return compiler.semantic.AbstractStatics.abstractOf(owner) ?? owner;

	static inline function parentPath(path:String):Null<String>
		return compiler.core.QualifiedName.parent(path);
}

/** A shared unit's output with its name, handed out of the arena that typed it. */
class SharedUnit {
	public final name:String;
	public final output:Null<TypingOutput>;

	public function new(name:String, output:Null<TypingOutput>) {
		this.name = name;
		this.output = output;
	}
}
