package compiler.types.typing;

import compiler.semantic.LambdaName;
import compiler.syntax.Ast.AstArgument;
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
import compiler.semantic.DeclarationFacts;
import compiler.semantic.DeclarationFacts.FactAspect;
import compiler.semantic.DeclarationPrints;
import compiler.semantic.DeclarationTable;

/** Where typing stood before a body: see `TypingSession.checkpoint`. */
typedef TypingCheckpoint = {
	final contexts:Int;

	/** How many units were recording their reads (`DeclarationReads.depth`). */
	final reads:Int;
	final outputs:Int;
	final output:TypingOutput;
	final defaultArgumentDepth:Int;
	final monomorphs:Int;
	final lintFacts:compiler.types.typing.UnitRecords.LintFactCounts;
	/** The body being typed, if any, and its counters, which typing that stops part way leaves raised. */
	final context:Null<TypingContext>;
	final loopDepth:Int;
	final privateAccessDepth:Int;
	final nullSafetyOffDepth:Int;
	final structureSwitches:Int;
	final nullSafetyFindings:Int;
}

/**
 * The typing state of one compilation: the program view bodies are typed against (declarations, relations, signatures,
 * representations, the facts about purity and no-return functions) and the body context stack, plus where typing writes:
 * the output of the unit being typed (`output`), merged into the program's (`programOutput`) in declaration order.
 */
class TypingSession {
	/** The program's functions by name (`SemanticProgram.signatures`): a lookup reads the function's signature. */
	public var signatures = new DeclarationTable<AstFunction>(FactAspect.Signature, FactAspect.Signature,
		DeclarationPrints.KIND_FUNCTIONS);

	/**
	 * What the program knows of each method, by name. Its values are flat records, so they stay in a map: a lookup goes through
	 * `methodInfoOf`, which reads the method's signature.
	 */
	var methodInfo:Map<String, SemanticMethodInfo> = [];

	/**
	 * `signatures` and `methodInfo` by owner, then member name, as the program bound last has them; a lookup of a member reads its
	 * signature (`readSignature`).
	 */
	public var signaturesByOwner:Map<String, Map<String, AstFunction>> = [];

	public var methodsByOwner:Map<String, Map<String, SemanticMethodInfo>> = [];

	/** What the program knows of method `name`, or null: a read of its signature. */
	public function methodInfoOf(name:String):Null<SemanticMethodInfo> {
		var recorder = reads();
		if (recorder != null)
			recorder.read(FactAspect.Signature, name);
		return methodInfo.get(name);
	}

	/**
	 * The enum `enumName`, for code that names its constructor `caseName` alone: a read of the enum's shape and of that constructor
	 * (its index and parameters), not of the enum's other constructors.
	 */
	public function enumConstructorDeclaration(enumName:String, caseName:String):compiler.syntax.Ast.AstEnum {
		var declaration = enumDecls.header(enumName), recorder = reads();
		if (declaration == null)
			throw new InternalError('Missing enum "$enumName"');
		if (recorder != null)
			recorder.read(FactAspect.Case, enumName + "." + caseName);
		return declaration;
	}

	/** Records that the unit being typed read the signature of `name`, as a lookup of the signature table reads it. */
	public function readSignature(name:String):Void {
		var recorder = reads();
		if (recorder != null)
			recorder.read(FactAspect.Signature, name);
	}

	/** Records that the unit being typed read the body of `name`. */
	public function readBody(name:String):Void {
		var recorder = reads();
		if (recorder != null)
			recorder.read(FactAspect.Body, name);
	}

	/** The program's static extensions (`StaticExtensions`), from the program bound last. */
	public var staticExtensions:compiler.semantic.StaticExtensionTable = compiler.semantic.StaticExtensionTable.empty();
	public final externals:Map<String, {arguments:Array<CompilerType>, result:CompilerType}>;
	public var classDecls:compiler.semantic.DeclarationTable<compiler.syntax.Ast.AstClass>;
	public var interfaceDecls:compiler.semantic.DeclarationTable<compiler.syntax.Ast.AstInterface>;
	public var enumDecls:compiler.semantic.DeclarationTable<compiler.syntax.Ast.AstEnum>;

	var enumsByFile:Null<Map<String, Array<{name:String, declaration:compiler.syntax.Ast.AstEnum}>>> = null;

	var enumAbstractsByFile:Null<Map<String, Array<compiler.syntax.Ast.AstAbstract>>> = null;

	public final enumRepresentations:EnumRuntimeRepresentations;
	public var enumAbstractDecls:compiler.semantic.DeclarationTable<compiler.syntax.Ast.AstAbstract>;

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

	public function endUnit(unit:TypingOutput):Void {
		if (output != unit)
			throw new InternalError("Typing outputs must be left in stack order");
		output = outputs.pop();
	}

	/**
	 * Records that the code being typed uses the shared unit `name`: a generic function specialization, an inline constant. What
	 * the shared unit read is read through it (`FactAspect.Unit`).
	 */
	public function useSharedUnit(name:String):Void {
		var recorder = reads();
		if (recorder != null)
			recorder.read(FactAspect.Unit, name);
		if (output != programOutput)
			output.recordUse(name, bodyContexts.length < 2 ? null : anonymousUnit());
	}

	/** Where the reads of the units typed are recorded, or null where nothing records. */
	inline function reads():Null<compiler.semantic.DeclarationReads>
		return declarations == null ? null : declarations.reads;

	/**
	 * Starts recording the reads of `unit`, which reads what it is made from: its own signature and body, a field's initializer,
	 * or the body and signature of the generic function a specialization is made from.
	 */
	function beginReads(unit:String):Bool {
		var recorder = reads();
		if (recorder == null)
			return false;
		recorder.begin(unit);
		var field = compiler.semantic.InitializerUnit.field(unit);
		if (field != null)
			recorder.read(FactAspect.Initializer, field);
		else if (StringTools.startsWith(unit, INLINE_CONSTANT_PREFIX))
			recorder.read(FactAspect.Initializer, unit.substr(INLINE_CONSTANT_PREFIX.length));
		else {
			var origin = compiler.semantic.GeneratedNames.specializedFunction(unit);
			recorder.read(FactAspect.Signature, origin);
			recorder.read(FactAspect.Body, origin);
			// A function is typed against the types its own signature names, whatever their kind: their members are its reads too.
			// Its callers read only the typedefs and abstracts the signature expands (`DeclarationFacts.setDependencies`).
			var facts = recorder.facts, named = facts.dependenciesOf(facts.id(FactAspect.Signature, origin));
			if (named != null)
				for (shape in named)
					recorder.read(FactAspect.Members, facts.name(shape));
			// A constructor starts with its class's instance field initializers, each typed as a unit of its own.
			if (StringTools.endsWith(origin, CONSTRUCTOR_SUFFIX)) {
				var owner = origin.substr(0, origin.length - CONSTRUCTOR_SUFFIX.length),
					declaration = classDecls == null ? null : classDecls.entry(owner);
				if (declaration != null) {
					recorder.read(FactAspect.Members, owner);
					for (method in declaration.methods)
						if (!method.isStatic && method.isDynamic == true)
							recorder.read(FactAspect.Signature, owner + "." + method.name);
					for (field in declaration.fields)
						if (!field.isStatic && field.initializer != null) {
							recorder.read(FactAspect.Initializer, owner + "." + field.name);
							recorder.read(FactAspect.Unit, compiler.semantic.InitializerUnit.of(owner, field.name));
						}
				}
			}
		}
		return true;
	}

	static inline final CONSTRUCTOR_SUFFIX = ".new";

	/** The body depths at which a shared unit records its reads: the body it enters there is the shared unit's, not a unit of its own. */
	final sharedReadDepths:Array<Int> = [];

	function beginSharedReads(name:String):Bool {
		if (!beginReads(name))
			return false;
		sharedReadDepths.push(bodyContexts.length);
		return true;
	}

	function endSharedReads(recording:Bool):Void
		if (recording) {
			sharedReadDepths.pop();
			reads().end();
		}

	/**
	 * Records what a unit the typer makes without typing a body reads (a constructor made of its class's field initializers): what
	 * it is made from, as `enterBody` records for a body.
	 */
	public function recordComposedUnit(unit:String):Void
		if (beginReads(unit))
			reads().end();

	/** The name prefix of an inline constant's shared unit (`InlineConstantResolver`). */
	public static inline final INLINE_CONSTANT_PREFIX = "$inline:";

	/**
	 * Types the shared unit `name` with `type`, into an output of its own when a unit is being typed. Call `useSharedUnit` first:
	 * the shared unit's output is merged where its first user in declaration order used it, whichever body typed it. With
	 * `checkOnly`, the unit is typed for its errors alone (`beginCheckUnit`): a specialization for type parameters of a body
	 * being checked, which no program code can call. With `unused`, no code has used it yet, so it is typed into an output of its
	 * own even outside any unit: it is merged only if code uses it.
	 */
	public function typeSharedUnit(name:String, type:() -> Void, checkOnly:Bool = false, unused:Bool = false):Void {
		if (output == programOutput && !checkOnly && !unused) {
			var recording = beginSharedReads(name);
			try {
				type();
			} catch (error:haxe.Exception) {
				endSharedReads(recording);
				throw error;
			}
			endSharedReads(recording);
			return;
		}
		var unit = new TypingOutput(true, bodyContexts.length, checkOnly);
		sharedOutputs.set(name, unit);
		outputs.push(output);
		output = unit;
		var recording = beginSharedReads(name);
		try {
			type();
		} catch (error:haxe.Exception) {
			endSharedReads(recording);
			endUnit(unit);
			throw error;
		}
		endSharedReads(recording);
		endUnit(unit);
	}

	/**
	 * The errors typing recovered from, in the order they were met: one per body (a function, a field initializer) whose typing
	 * failed. The program typer goes on with the next body, then fails with all of them (`failIfRecovered`).
	 */
	public final recoveredErrors:Array<Diagnostic> = [];

	/**
	 * Where typing stands, to come back to when what is typed next fails: between bodies (`recover`), or between the statements
	 * of a body (`BodyTyper.typeStatements`).
	 */
	public function checkpoint():TypingCheckpoint {
		var context = bodyContexts.length == 0 ? null : currentContext;
		var recorder = reads();
		return {
			contexts: bodyContexts.length,
			reads: recorder == null ? 0 : recorder.depth,
			outputs: outputs.length,
			output: output,
			defaultArgumentDepth: defaultArgumentDepth,
			monomorphs: monomorphs.depth(),
			lintFacts: output.records.lintFactCounts(),
			context: context,
			loopDepth: context == null ? 0 : context.loopDepth,
			privateAccessDepth: context == null ? 0 : context.privateAccessDepth,
			nullSafetyOffDepth: context == null ? 0 : context.nullSafetyOffDepth,
			structureSwitches: context == null ? 0 : context.structureSwitches.length,
			nullSafetyFindings: nullSafety.findings.length
		};
	}

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
		var recorder = reads();
		if (recorder != null)
			recorder.endTo(mark.reads);
		if (bodyContexts.length > mark.contexts)
			bodyContexts.splice(mark.contexts, bodyContexts.length - mark.contexts);
		if (outputs.length > mark.outputs)
			outputs.splice(mark.outputs, outputs.length - mark.outputs);
		output = mark.output;
		// What typing abandons was never typed: a speculative typing's findings are not the program's.
		if (nullSafety.findings.length > mark.nullSafetyFindings)
			nullSafety.findings.resize(mark.nullSafetyFindings);
		// A body typed in the output it returns to (a field initializer, in its class's) takes back the lint facts it recorded.
		output.records.truncateLintFacts(mark.lintFacts);
		defaultArgumentDepth = mark.defaultArgumentDepth;
		var context = mark.context;
		if (context != null) {
			context.loopDepth = mark.loopDepth;
			context.privateAccessDepth = mark.privateAccessDepth;
			context.nullSafetyOffDepth = mark.nullSafetyOffDepth;
			if (context.structureSwitches.length > mark.structureSwitches)
				context.structureSwitches.splice(mark.structureSwitches,
					context.structureSwitches.length - mark.structureSwitches);
		}
	}

	/** The null-safety errors of the bodies typed, which fail the typing as a failed body's error does. */
	function recordNullSafetyFindings():Void
		for (finding in nullSafety.takeFindings())
			recordRecovered(finding);

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
		recordNullSafetyFindings();
		if (recoveredErrors.length == 0)
			return;
		var table = types;
		throw new TypingFailure(recoveredErrors.copy(), typed, programOutput.records.unboundLocals.copy(),
			programOutput.records.nonExceptionThrows.copy(), table == null ? [] : table.knownFieldTypes(),
			table == null ? [] : table.typedSignatures());
	}

	/** `error`, with the errors recovered before it first: what a typing that stops at `error` fails with. */
	public function withRecovered(error:CompileError):CompileError {
		recordNullSafetyFindings();
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
		this.nullSafety = new NullSafety(this);
	}

	/** The null-safety checker of the bodies this session types. */
	public final nullSafety:NullSafety;

	/** The span of the lambda being typed as a call's argument, which runs during the call (`CallResolver.typeCallArgument`). */
	public var immediateLambda:Null<SourceSpan> = null;

	/** Whether a body is being typed. */
	public inline function hasBody():Bool
		return bodyContexts.length > 0;

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
		types = new DeclarationTypeTable(declarations.declaredTypes, semantic, defaultValueType, this, typing);
		declarations.bindTypes(types);
		relations = semantic.relations;
		signatures = new DeclarationTable(FactAspect.Signature, FactAspect.Signature, DeclarationPrints.KIND_FUNCTIONS,
			semantic.signatures);
		methodInfo = semantic.methodInfo;
		signaturesByOwner = semantic.signaturesByOwner;
		methodsByOwner = semantic.methodsByOwner;
		signatures.reads = declarations.reads;
		staticExtensions = semantic.staticExtensions;
		enumDecls = declarations.enums;
		enumsByFile = null;
		enumAbstractsByFile = null;
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
			for (name => declaration in enumDecls.withoutReads()) {
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
		// What a file's enums are is a read of each of them, whichever unit built the index.
		var recorder = reads();
		if (recorder != null && found != null)
			for (entry in found)
				recorder.read(FactAspect.Members, entry.name);
		return found == null ? noEnums : found;
	}

	/**
	 * The enum abstracts declared in the file at `path`. A bare value name with no expected type resolves
	 * against them, its own abstract's and the imported ones (which name resolution qualifies), as in Haxe.
	 */
	public function enumAbstractsInFile(path:String):Array<compiler.syntax.Ast.AstAbstract> {
		var index = enumAbstractsByFile;
		if (index == null) {
			index = [];
			for (declaration in enumAbstractDecls.withoutReads()) {
				var filePath = declaration.span.file.path,
					entries = index.get(filePath);
				if (entries == null) {
					entries = [];
					index.set(filePath, entries);
				}
				entries.push(declaration);
			}
			enumAbstractsByFile = index;
		}
		var found = index.get(path);
		// What a file's enum abstracts are is a read of each of them, whichever unit built the index.
		var recorder = reads();
		if (recorder != null && found != null)
			for (declaration in found)
				recorder.read(FactAspect.Members, declaration.name);
		return found == null ? noEnumAbstracts : found;
	}

	@:processWide("a shared empty value, never added to")
	static final noEnumAbstracts:Array<compiler.syntax.Ast.AstAbstract> = [];

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
	 * The unit being typed reads the answer (`FactAspect.Purity`): typed bodies are cached between incremental compiles, so a
	 * later compile whose purity answer for `name` changed types this body again, even though its own source did not change.
	 */
	public function isPureCall(name:String):Bool {
		var answer = inferredPureFunctions.exists(name) || isDeclaredPure(name);
		var recorder = reads();
		if (recorder != null)
			recorder.read(FactAspect.Purity, name);
		return answer;
	}

	/**
	 * Records that the unit being typed read what `unit` gave an unannotated declaration: its result and arguments, or its field's
	 * type (`DeclarationTypeTable`), which change with whatever `unit` read.
	 */
	public function readUnit(unit:String):Void {
		var recorder = reads();
		if (recorder != null)
			recorder.read(FactAspect.Unit, unit);
	}

	/** A value method can have global effects without writing its receiver. */
	public function isReadOnlyReceiver(name:String):Bool {
		var key = compiler.types.analysis.ReceiverMutationInference.PREFIX + name,
			answer = inferredPureFunctions.exists(key);
		var recorder = reads();
		if (recorder != null)
			recorder.read(FactAspect.Purity, key);
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

	/**
		Forgets in `scope` what a call of `setter`, the setter of instance property `property`, can change. An inline setter
		cannot be overridden and its body is part of the call, so it forgets only the fields that body stores to.
	 */
	public function invalidateSetterEffects(setter:String, property:String, scope:Scope):Void {
		if (isPureCall(setter))
			return;
		var fields = inlineSetterStores(setter, property);
		if (fields == null) {
			invalidateUnknownCall(scope);
			return;
		}
		for (field in fields)
			scope.invalidateField(field);
	}

	function inlineSetterStores(setter:String, property:String):Null<Array<String>> {
		var fn = signatures.get(setter), owner = compiler.core.QualifiedName.parent(setter);
		if (fn == null || fn.isInline != true || owner == null)
			return null;
		readBody(setter);
		var found = compiler.types.analysis.PurityInference.setterStores(localPurityInference(), fn, owner, property),
			recorder = reads();
		if (recorder != null)
			recorder.read(FactAspect.Members, owner);
		return found == null || !dependenciesArePure(found.dependencies) ? null : found.fields;
	}

	/** Annotated functions and read-only compiler intrinsics; the inference seeds from these. */
	function isDeclaredPure(name:String):Bool
		return compiler.types.analysis.PurityAnnotations.isDeclaredPure(name, signatures.withoutReads(),
			classDecls.withoutReads());

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
	public function bodyIsPure(arguments:Array<AstArgument>,
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
			inference = compiler.types.analysis.PurityInference.create(signatures.withoutReads(),
				classDecls.withoutReads(), enumDecls.withoutReads(),
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
		inferredPureFunctions = compiler.types.analysis.PurityInference.infer(signatures.withoutReads(),
			classDecls.withoutReads(),
			declarations.abstracts.withoutReads(), enumDecls.withoutReads(), isDeclaredPure,
			isTypeName);
	}

	function isTypeName(name:String):Bool
		return compiler.types.analysis.PurityAnnotations.isTypeName(name, classDecls.withoutReads(),
			interfaceDecls.withoutReads(), enumDecls.withoutReads(),
			declarations.abstracts.withoutReads())
			|| enumAbstractName(name) != null;

	public function hasPureAnnotation(name:String):Bool
		return compiler.types.analysis.PurityAnnotations.hasPureAnnotation(name, signatures.withoutReads(),
			classDecls.withoutReads());

	/** Whether a call to `name` was typed as never returning; recorded the same way as `isPureCall`. */
	public function isNoReturnCall(name:String):Bool {
		var answer = noReturnFunctions.exists(name);
		var recorder = reads();
		if (recorder != null)
			recorder.read(FactAspect.NoReturn, name);
		return answer;
	}

	/** Select and register the concrete storage for a Map. */
	public function mapName(key:CompilerType, value:CompilerType):Null<String> {
		var owner = mapOwner(key, value);
		if (owner != null) {
			runtimeDependencyTracker.record(currentContext.name, owner);
			representation.specializedMapOwner(owner, key, value);
			return owner;
		}
		return isPayloadEnumKey(key) ? null : RuntimeType.mapName(key, value);
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

	public function mapOwner(key:CompilerType, value:CompilerType):Null<String> {
		var hashable = DeclaredConformance.has(this, key, "Hashable");
		// Payload enum keys use their declared hash and equality.
		if (isPayloadEnumKey(key))
			return hashable ? RuntimeType.SPECIALIZED_MAP : null;
		if (!hashable && RuntimeType.mapName(key, value) == null)
			return switch key {
				case TInstance(NominalKind.Class | NominalKind.Interface, _, _) if (!relations.isStruct(key)):
					RuntimeType.OBJECT_MAP;
				default: null;
			};
		return RuntimeType.usesSpecializedMap(key, value, mapValueType, _ -> hashable)
			? RuntimeType.SPECIALIZED_MAP : null;
	}

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
			?sourceFunctionName:String):TypingContext
		return enter(name, typeSubstitutions, ownerOverride, sourceFunctionName, true);

	/**
	 * Asks for a generated helper (`HelperRequests`). A helper is typed only from requests, so the code asking reads the helper's
	 * unit: when what the helper read changes, the code is typed again and asks for it again, as a fresh build does.
	 */
	public function requestHelper(request:HelperRequests.HelperRequest):Bool {
		var unit = HelperRequests.unitOf(request);
		if (unit != null)
			readUnit(unit);
		return output.requests.add(request);
	}

	/**
	 * Enters the body of `origin`, the code generated helper `helper` was first requested from, to type the helper as that code
	 * sees it; `ownerless` is the owner when `origin` has none. It is no unit of `origin`'s, which would replace what `origin` read
	 * in a build that keeps its body: what it reads is the helper's unit's (`typeHelper`).
	 */
	public function enterHelperBody(helper:String, origin:String, ownerless:String):TypingContext {
		var body = enter(origin, null, parentPath(origin) ?? ownerless, null, false);
		body.recordsReads = beginHelperReads(helper);
		return body;
	}

	/** Makes generated helper `helper` with `make`, recording what it reads as the helper's unit (`requestHelper`). */
	public function typeHelper<T>(helper:String, make:() -> T):T {
		var recording = beginHelperReads(helper);
		try {
			var made = make();
			if (recording)
				reads().end();
			return made;
		} catch (error:haxe.Exception) {
			if (recording)
				reads().end();
			throw error;
		}
	}

	function beginHelperReads(helper:String):Bool {
		var recorder = reads();
		if (recorder == null)
			return false;
		recorder.begin(helper);
		return true;
	}

	function enter(name:String, typeSubstitutions:Null<Map<String, CompilerType>>, ownerOverride:Null<String>,
			sourceFunctionName:Null<String>, unit:Bool):TypingContext {
		var isLambda = LambdaName.is(name),
			owner = codeOwner(ownerOverride != null ? ownerOverride : isLambda
				? currentContext.lexicalOwner : parentPath(name)),
			source = sourceFunctionName != null ? sourceFunctionName : isLambda
				? currentContext.sourceFunctionName : null,
			body = new TypingContext(name, typeSubstitutions, owner, source);
		nullSafety.enter(body, bodyContexts.length == 0 ? null : currentContext);
		if (isLambda) {
			body.privateAccessDepth = currentContext.privateAccessDepth;
			body.memberInitializer = currentContext.memberInitializer;
			body.resolution = currentContext.resolution;
		}
		// A unit's outermost body: a top-level one, or a declaration's unit typed on demand inside another body.
		if (unit && (bodyContexts.length == 1 || !output.shared && bodyContexts.length == output.baseDepth)) {
			programOutput.records.typedUnits.set(name, true);
			if (sharedReadDepths.length == 0 || sharedReadDepths[sharedReadDepths.length - 1] != bodyContexts.length)
				body.recordsReads = beginReads(name);
		}
		if (StringTools.startsWith(name, DEFAULT_ARGUMENT_PREFIX))
			defaultArgumentDepth++;
		bodyContexts.push(body);
		return body;
	}

	/** Records a warning on the body being typed: the innermost one that is not a lambda, since a lambda is part of its function. */
	public function warn(diagnostic:Diagnostic):Void {
		var index = bodyContexts.length - 1;
		while (index > 0 && LambdaName.is(bodyContexts[index].name))
			index--;
		bodyContexts[index].warnings.push(diagnostic);
	}

	public function withLexicalContext<T>(context:TypingContext, run:() -> T):T {
		var depth = bodyContexts.length;
		if (currentContext != context)
			bodyContexts.push(context);
		try {
			var result = run();
			bodyContexts.resize(depth);
			return result;
		} catch (error:haxe.Exception) {
			bodyContexts.resize(depth);
			throw error;
		}
	}

	public function leaveBody(body:TypingContext):Void {
		if (currentContext != body)
			throw new InternalError("Body typing contexts must be left in stack order");
		bodyContexts.pop();
		if (body.recordsReads)
			reads().end();
		if (StringTools.startsWith(body.name, DEFAULT_ARGUMENT_PREFIX))
			defaultArgumentDepth--;
	}

	/** The declaration whose code a body of `owner` is: an abstract's, for its statics' storage class (`TypeStatics`). */
	static function codeOwner(owner:Null<String>):Null<String>
		return compiler.semantic.TypeStatics.ownerOf(owner) ?? owner;

	static inline function parentPath(path:String):Null<String>
		return compiler.core.QualifiedName.parent(path);
}
