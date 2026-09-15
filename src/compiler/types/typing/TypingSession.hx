package compiler.types.typing;

import compiler.semantic.GenericSpecializationRegistry;
import compiler.semantic.SemanticProgram;
import compiler.semantic.SemanticProgram.SemanticMethodInfo;
import compiler.runtime.RuntimeType;
import compiler.syntax.Ast.AstFunction;
import compiler.Diagnostic;
import compiler.Diagnostic.DiagnosticOrigin;
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

	/** Keep typing local when the input is an editor recovery tree. */
	public final tolerant:Bool;

	final checkpointCallback:Null<Void->Void>;

	public final nativeLayoutsByName:Map<String, TypedNativeLayout> = [];
	public final emittedGenericBodies:Map<String, Bool> = [];
	public final noReturnFunctions:Map<String, Bool> = [];
	public final runtimeDependencyTracker = new RuntimeDependencyTracker();
	public final wireCodecRequests:Map<String, WireCodecRequest> = [];
	public final cNativeFunctions:Map<String, Bool> = [];
	public final inlineConstants:Map<String, ResolvedInlineConstant> = [];
	public final inlineConstantsInProgress:Map<String, Bool> = [];

	/** Diagnostics captured when tolerant editor typing localizes a failure. */
	public final recoveryDiagnostics:Array<Diagnostic> = [];

	public var functionAdapterCounter:Int = 0;
	public final representation:TypeRepresentation;

	public var currentContext(get, never):TypingContext;

	inline function get_currentContext():TypingContext
		return bodyContexts[bodyContexts.length - 1];

	public function new(externals:Null<Map<String, {arguments:Array<CompilerType>, result:CompilerType}>>,
			specializations:Null<GenericSpecializationRegistry>, ?nativeAbiTarget:String, tolerant:Bool = false, ?checkpoint:Void->Void) {
		this.externals = externals == null ? [] : externals;
		this.genericSpecializations = specializations == null ? new GenericSpecializationRegistry() : specializations;
		this.nativeAbiTarget = nativeAbiTarget == null ? "portable-abi64" : nativeAbiTarget;
		this.representation = new TypeRepresentation(this);
		this.tolerant = tolerant;
		this.checkpointCallback = checkpoint;
	}

	public inline function checkpoint():Void {
		if (checkpointCallback != null)
			checkpointCallback();
	}

	public function rememberRecoveryDiagnostic(diagnostic:Diagnostic):Void {
		diagnostic.origin = DiagnosticOrigin.Semantic;
		for (existing in recoveryDiagnostics)
			if (existing.code == diagnostic.code
				&& existing.span.file.path == diagnostic.span.file.path
				&& existing.span.start == diagnostic.span.start
				&& existing.span.end == diagnostic.span.end
				&& existing.message == diagnostic.message)
				return;
		recoveryDiagnostics.push(diagnostic);
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
