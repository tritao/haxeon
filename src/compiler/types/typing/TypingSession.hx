package compiler.types.typing;

import compiler.semantic.GenericSpecializationRegistry;
import compiler.semantic.SemanticProgram;
import compiler.semantic.SemanticProgram.SemanticMethodInfo;
import compiler.runtime.RuntimeType;
import compiler.syntax.Ast.AstFunction;
import compiler.types.analysis.ClosureConversion;
import compiler.types.Type.CompilerType;
import compiler.types.Type.NominalKind;
import compiler.types.TypedAst.TypedExpression;
import compiler.types.TypedAst.TypedNativeLayout;
import compiler.Source.SourceSpan;
import compiler.types.analysis.Scope;

typedef ResolvedInlineConstant = {
	final initializer:TypedExpression;
	final value:TypedExpression;
}

typedef WireCodecRequest = {
	final type:CompilerType;
	final origin:String;
	final span:SourceSpan;
}

typedef EqualityRequest = {
	final type:CompilerType;
	final origin:String;
	final span:SourceSpan;
}

typedef EnumMethodRequest = {
	final type:CompilerType;
	final method:String;
	final origin:String;
	final span:SourceSpan;
}

typedef EnumInterfaceAdapterRequest = {
	final type:CompilerType;
	final interfaceType:CompilerType;
	final origin:String;
	final span:SourceSpan;
}

/** Mutable semantic state shared by all typing phases for one compilation. */
class TypingSession {
	public var signatures:Map<String, AstFunction> = [];

	public var methodInfo:Map<String, SemanticMethodInfo> = [];
	public final externals:Map<String, {arguments:Array<CompilerType>, result:CompilerType}>;
	public var classDecls:Map<String, compiler.syntax.Ast.AstClass> = [];
	public var interfaceDecls:Map<String, compiler.syntax.Ast.AstInterface> = [];
	public var enumDecls:Map<String, compiler.syntax.Ast.AstEnum> = [];

	var enumsByFile:Null<Map<String, Array<{name:String, declaration:compiler.syntax.Ast.AstEnum}>>> = null;

	public final enumRepresentations:EnumRuntimeRepresentations;
	public var enumAbstractDecls:Map<String, compiler.syntax.Ast.AstEnumAbstract> = [];
	public var declarations:DeclarationIndex;
	public var relations:TypeRelations;
	public final closureConversion = new ClosureConversion();

	/** Typed lambdas by position and captured bindings: the copies of a switch arm with several patterns capture different locals. */
	public final lambdaCache:Map<String, TypedExpression> = [];

	/** How many variants (see `lambdaCache`) each lambda position has been typed as. */
	public final lambdaVariants:Map<String, Int> = [];

	/** Structural conversion helpers already emitted for each origin and target shape. */
	public final dynamicStructureConversions:Map<String, Bool> = [];

	public final bodyContexts:Array<TypingContext> = [new TypingContext("")];

	/**
	 * The anonymous types registered while each unit was typed: a function, or the field initializers of a class (`Class.__init`).
	 * A nested body (a lambda) belongs to the unit it is written in. A build that types a unit again records it afresh; one that does
	 * not keeps the earlier record in the program (see `ProgramTyper.keepAnonymousUnits`), so a type only unchanged code uses stays.
	 */
	public final anonymousUnits:Map<String, Map<String, Array<compiler.types.Type.AnonymousField>>> = [];

	/** The units whose bodies this session typed. */
	public final typedUnits:Map<String, Bool> = [];

	public function recordAnonymousUse(name:String, fields:Array<compiler.types.Type.AnonymousField>):Void {
		if (bodyContexts.length < 2)
			return;
		var unit = bodyContexts[1].name, uses = anonymousUnits.get(unit);
		if (uses == null) {
			uses = [];
			anonymousUnits.set(unit, uses);
		}
		uses.set(name, fields);
	}

	public final anonymousTypes:Map<String, Array<compiler.types.Type.AnonymousField>> = [];
	public final genericSpecializations:GenericSpecializationRegistry;
	public final nativeAbiTarget:String;
	public final nativeLayoutsByName:Map<String, TypedNativeLayout> = [];
	public final emittedGenericBodies:Map<String, Bool> = [];
	public final noReturnFunctions:Map<String, Bool> = [];
	public final runtimeDependencyTracker = new RuntimeDependencyTracker();
	public final wireCodecRequests:Map<String, WireCodecRequest> = [];
	public final jsonCodecRequests:Map<String, WireCodecRequest> = [];

	/** Language `==` on declared values follows their one conformance equality. */
	public final valueEqualityRequests:Map<String, EqualityRequest> = [];

	/** Static Type.enumEq comparisons use enum tags and payloads without declaring enum value conformance. */
	public final enumEqualityRequests:Map<String, EqualityRequest> = [];

	/** Concrete enum interface methods requested by statically dispatched calls. */
	public final enumMethodRequests:Map<String, EnumMethodRequest> = [];

	/** Real enum-to-interface conversions need an interface-dispatch object. */
	public final enumInterfaceAdapters:Map<String, EnumInterfaceAdapterRequest> = [];

	/** Hash implementations generated from declared `Hashable` conformance. */
	public final hashRequests:Map<String, EqualityRequest> = [];
	public final rawRepresentableRequests:Map<String, {owner:String, method:String, origin:String, span:SourceSpan}> = [];

	public final cNativeFunctions:Map<String, Bool> = [];
	public final inlineConstants:Map<String, ResolvedInlineConstant> = [];
	public final inlineConstantsInProgress:Map<String, Bool> = [];
	public final enumAbstractConstants:Map<String, compiler.types.TypedAst.TypedExpression> = [];
	public final enumAbstractConstantsInProgress:Map<String, Bool> = [];
	public var enumAbstractConstantOwner:Null<String> = null;

	/** Resolved field sequences used by path operations and descriptor generation. */
	public final keyPathDefinitions:Map<String, KeyPathTyping.KeyPathDefinition> = [];

	public final keyPathParameters:Map<String, Map<String, String>> = [];
	public final keyPathCompositions:Map<String, Bool> = [];

	/**
	 * Function adapters already made in each body, so an adapter's name depends on its position in its own function. A
	 * counter shared by the whole typing run made the name depend on how many adapters other functions had made before it,
	 * which differs between a build that types everything and one that retypes only what changed.
	 */
	public final functionAdapterCounts:Map<String, Int> = [];

	public final substrCounts:Map<String, Int> = [];

	public final representation:TypeRepresentation;

	public var currentContext(get, never):TypingContext;

	inline function get_currentContext():TypingContext
		return bodyContexts[bodyContexts.length - 1];

	public function new(externals:Null<Map<String, {arguments:Array<CompilerType>, result:CompilerType}>>,
			specializations:Null<GenericSpecializationRegistry>, ?nativeAbiTarget:String) {
		this.externals = externals == null ? [] : externals;
		this.genericSpecializations = specializations == null ? new GenericSpecializationRegistry() : specializations;
		this.nativeAbiTarget = nativeAbiTarget == null ? "portable-abi64" : nativeAbiTarget;
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
				span == null ? fallback : span;
			case TInt, TInt64, TFloat, TBool, TString, TNativeScalar(_), TKeyPath(_, _, _): builtinHelperSpan;
			case _: fallback;
		};
	}

	public function bindSemantic(semantic:SemanticProgram):Void {
		enumAbstractConstants.clear();
		enumAbstractConstantsInProgress.clear();
		for (declaration in semantic.program.enums)
			helperSpans.set(declaration.name, declaration.span);
		for (declaration in semantic.program.classes)
			helperSpans.set(declaration.name, declaration.span);
		for (declaration in semantic.program.abstracts)
			helperSpans.set(declaration.name, declaration.span);

		declarations = semantic.declarations;
		relations = semantic.relations;
		signatures = semantic.signatures;
		methodInfo = semantic.methodInfo;
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

	static final noEnums:Array<{name:String, declaration:compiler.syntax.Ast.AstEnum}> = [];

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
		recordQuery(purityQueries, name, answer);
		return answer;
	}

	/** A value method can have global effects without writing its receiver. */
	public function isReadOnlyReceiver(name:String):Bool {
		var key = compiler.types.analysis.ReceiverMutationInference.PREFIX + name,
			answer = inferredPureFunctions.exists(key);
		recordQuery(purityQueries, key, answer);
		return answer;
	}

	/** Whether writes through a binding may update the binding itself rather than a referenced object. */
	public function mayHoldValue(type:Null<compiler.syntax.Ast.AstType>, initializer:Null<compiler.syntax.Ast.AstExpression>):Bool {
		if (type != null && (switch (type) {
			case InferredType: false;
			default: true;
		})) {
			var resolved:Null<CompilerType> = null;
			try {
				resolved = declarations.resolve(type, null, currentContext.typeSubstitutions);
			} catch (_:compiler.Diagnostic.CompileError) {
				// The normal typing pass reports invalid or inferred annotations with the right source context.
				return true;
			}
			if (resolved == null)
				return true;
			return valueStorageType(resolved);
		}
		return switch initializer {
			case New(name, _, _) if (classDecls.exists(name)): relations.isValueClass(TInstance(NominalKind.Class, name, []));
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
	public function mayBeKeyPath(type:Null<compiler.syntax.Ast.AstType>, initializer:Null<compiler.syntax.Ast.AstExpression>):Bool {
		if (type != null && (switch type {
			case InferredType: false;
			default: true;
		})) {
			try {
				return switch declarations.resolve(type, null, currentContext.typeSubstitutions) {
					case TKeyPath(_, _, _), TDynamic, TTypeParameter(_, _): true;
					default: false;
				};
			} catch (_:compiler.Diagnostic.CompileError)
				return true;
		}
		return switch initializer {
			case New(_, _, _), ArrayLiteral(_, _), ObjectLiteral(_, _), Lambda(_, _, _, _): false;
			default: true;
		};
	}

	/** Only closure-written declarations can change during a call; respect local shadowing. */
	public function closureWritableNames(scope:Scope):Array<String> {
		return [
			for (name => declaration in scope.visibleDeclarations())
				if (currentContext.storage.closureWrites.exists(declaration)) name
		];
	}

	/** An impure call may invoke an escaped closure, including one forwarded through a named function. */
	public function invalidateUnknownCall(scope:Scope):Void {
		for (captured in closureWritableNames(scope))
			scope.invalidate(captured);
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
	public function bodyIsPure(arguments:Array<compiler.syntax.Ast.AstArgument>, body:Array<compiler.syntax.Ast.AstStatement>, outerLocals:Array<String>,
			owner:Null<String>, ?privateMaps:Array<String>):Bool {
		var dependencies = compiler.types.analysis.PurityInference.localBodyDependencies(localPurityInference(), arguments, body,
			owner == null ? "$local" : owner + ".$local", outerLocals, privateMaps);
		return dependencies != null && dependenciesArePure(dependencies);
	}

	/**
		For a loop body: the fields it stores to and whether it stores to an element (array or map), when that is all
		it does to state anyone else can see; null when it may have any other effect.
	 */
	public function bodyStores(body:Array<compiler.syntax.Ast.AstStatement>, outerLocals:Array<String>, owner:Null<String>, ?privateMaps:Array<String>,
			?outerArrays:Array<String>, ?outerMaps:Array<String>):Null<{
			fields:Array<String>,
			indexed:Bool
		}> {
		var found = compiler.types.analysis.PurityInference.localBodyStores(localPurityInference(), body, owner == null ? "$local" : owner + ".$local",
			outerLocals, privateMaps, outerArrays, outerMaps);
		if (found == null || !dependenciesArePure(found.dependencies))
			return null;
		return {fields: found.fields, indexed: found.indexed};
		}

	function localPurityInference():compiler.types.analysis.PurityInference {
		var inference = localPurity;
		if (inference == null) {
			inference = compiler.types.analysis.PurityInference.create(signatures, classDecls, enumDecls, isDeclaredPure, isTypeName);
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
		inferredPureFunctions = compiler.types.analysis.PurityInference.infer(signatures, classDecls, declarations.abstracts, enumDecls, isDeclaredPure,
			isTypeName);
	}

	function isTypeName(name:String):Bool
		return compiler.types.analysis.PurityAnnotations.isTypeName(name, classDecls, interfaceDecls, enumDecls, enumAbstractDecls, declarations.abstracts);

	public function hasPureAnnotation(name:String):Bool
		return compiler.types.analysis.PurityAnnotations.hasPureAnnotation(name, signatures, classDecls);

	/** Whether a call to `name` was typed as never returning; recorded the same way as `isPureCall`. */
	public function isNoReturnCall(name:String):Bool {
		var answer = noReturnFunctions.exists(name);
		recordQuery(noReturnQueries, name, answer);
		return answer;
	}

	/** Purity/no-return answers the function currently being typed asked about, keyed by that
	 * function's own name (or a lambda's synthetic name, itself tied back to its origin).
	 */
	public final purityQueries:Map<String, Map<String, Bool>> = [];

	public final noReturnQueries:Map<String, Map<String, Bool>> = [];

	/** The key path literals (`$keypath.literal:...`) each function being typed uses, by that function's name. */
	public final keyPathUses:Map<String, Map<String, Bool>> = [];

	public function recordKeyPathUse(user:String, literal:String):Void {
		var literals = keyPathUses.get(user);
		if (literals == null) {
			literals = [];
			keyPathUses.set(user, literals);
		}
		literals.set(literal, true);
	}

	/** Constants substituted into each typed body, including its omitted call arguments. */
	public final inlineConstantDependencies:Map<String, Map<String, Bool>> = [];

	/** Source snapshots copied into callers when omitted arguments use declaration syntax. */
	public final defaultArgumentSources:Map<String, Map<String, compiler.Source.SourceFile>> = [];

	function recordQuery(target:Map<String, Map<String, Bool>>, name:String, answer:Bool):Void {
		var caller = currentContext.name;
		if (caller == "")
			return;
		var record = target.get(caller);
		if (record == null) {
			record = [];
			target.set(caller, record);
		}
		record.set(name, answer);
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
			|| RuntimeType.usesSpecializedMap(key, value, mapValueType, type -> DeclaredConformance.has(this, type, "Hashable"));

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

	public function enterBody(name:String, ?typeSubstitutions:Map<String, CompilerType>, ?ownerOverride:String, ?sourceFunctionName:String):TypingContext {
		var owner = ownerOverride != null ? ownerOverride : compiler.semantic.LambdaName.is(name) ? currentContext.lexicalOwner : parentPath(name),
			body = new TypingContext(name, typeSubstitutions, owner, sourceFunctionName);
		if (bodyContexts.length == 1)
			typedUnits.set(name, true);
		bodyContexts.push(body);
		return body;
	}

	public function leaveBody(body:TypingContext):Void {
		if (currentContext != body)
			throw "Body typing contexts must be left in stack order";
		bodyContexts.pop();
	}

	static inline function parentPath(path:String):Null<String>
		return compiler.QualifiedName.parent(path);
}
