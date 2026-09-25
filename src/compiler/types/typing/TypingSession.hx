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

typedef ResolvedInlineConstant = {
	final initializer:TypedExpression;
	final value:TypedExpression;
}

typedef WireCodecRequest = {
	final type:CompilerType;
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
	public var enumAbstractDecls:Map<String, compiler.syntax.Ast.AstEnumAbstract> = [];
	public var declarations:DeclarationIndex;
	public var relations:TypeRelations;
	public final closureConversion = new ClosureConversion();
	public final lambdaCache:Map<String, TypedExpression> = [];
	public final bodyContexts:Array<TypingContext> = [new TypingContext("")];
	public final anonymousTypes:Map<String, Array<compiler.types.Type.AnonymousField>> = [];
	public final genericSpecializations:GenericSpecializationRegistry;
	public final nativeAbiTarget:String;
	public final nativeLayoutsByName:Map<String, TypedNativeLayout> = [];
	public final emittedGenericBodies:Map<String, Bool> = [];
	public final noReturnFunctions:Map<String, Bool> = [];
	public final runtimeDependencyTracker = new RuntimeDependencyTracker();
	public final wireCodecRequests:Map<String, WireCodecRequest> = [];
	public final cNativeFunctions:Map<String, Bool> = [];
	public final inlineConstants:Map<String, ResolvedInlineConstant> = [];
	public final inlineConstantsInProgress:Map<String, Bool> = [];
	public var functionAdapterCounter:Int = 0;
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
	}

	public function bindSemantic(semantic:SemanticProgram):Void {
		declarations = semantic.declarations;
		relations = semantic.relations;
		signatures = semantic.signatures;
		methodInfo = semantic.methodInfo;
		enumDecls = declarations.enums;
		enumAbstractDecls = declarations.enumAbstracts;
	}

	public function bindNominalDeclarations():Void {
		interfaceDecls = declarations.interfaces;
		classDecls = declarations.classes;
	}

	/** `@:pure` on a function, or on the class of a static method, promises no observable writes.
	 * Calls to annotated or inferred-pure functions keep flow facts about mutable fields and map entries.
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

	/** Annotated functions and read-only compiler intrinsics; the inference seeds from these. */
	function isDeclaredPure(name:String):Bool
		return compiler.types.analysis.PurityAnnotations.isDeclaredPure(name, signatures, classDecls);

	/** Static and module functions inferred pure by `PurityInference`. */
	public var inferredPureFunctions:Map<String, Bool> = [];

	public function inferPureFunctions():Void {
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

	/** Resolve a source Map ABI, restricting enum keys to nullary constructors. */
	public function mapName(key:CompilerType, value:CompilerType):Null<String> {
		var enumKey = enumKeyType(key);
		if (enumKey != null) {
			if (enumKey.arguments.length != 0)
				return null;
			var declaration = enumDecls.get(enumKey.name);
			if (declaration == null)
				return null;
			for (constructor in declaration.cases)
				if (constructor.params.length != 0)
					return null;
		}
		return RuntimeType.mapName(key, value);
	}

	static function enumKeyType(type:CompilerType):Null<{name:String, arguments:Array<CompilerType>}> {
		return switch type {
			case TAbstract(_, _, representation): enumKeyType(representation);
			case TInstance(NominalKind.Enum, name, arguments): {name: name, arguments: arguments};
			default: null;
		};
	}

	public function enterBody(name:String, ?typeSubstitutions:Map<String, CompilerType>, ?ownerOverride:String):TypingContext {
		var owner = ownerOverride != null ? ownerOverride : StringTools.startsWith(name, "$lambda:") ? currentContext.lexicalOwner : parentPath(name),
			body = new TypingContext(name, typeSubstitutions, owner);
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
