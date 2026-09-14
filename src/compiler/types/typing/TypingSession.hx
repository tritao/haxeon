package compiler.types.typing;

import compiler.semantic.GenericSpecializationRegistry;
import compiler.semantic.SemanticProgram;
import compiler.semantic.SemanticProgram.SemanticMethodInfo;
import compiler.syntax.Ast.AstFunction;
import compiler.types.analysis.ClosureConversion;
import compiler.types.Type.CompilerType;
import compiler.types.TypedAst.TypedExpression;

typedef ResolvedInlineConstant = {
	final initializer:TypedExpression;
	final value:TypedExpression;
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
	public final emittedGenericBodies:Map<String, Bool> = [];
	public final noReturnFunctions:Map<String, Bool> = [];
	public final runtimeDependencyTracker = new RuntimeDependencyTracker();
	public final cNativeFunctions:Map<String, Bool> = [];
	public final inlineConstants:Map<String, ResolvedInlineConstant> = [];
	public final inlineConstantsInProgress:Map<String, Bool> = [];
	public var functionAdapterCounter:Int = 0;

	public var currentContext(get, never):TypingContext;

	inline function get_currentContext():TypingContext
		return bodyContexts[bodyContexts.length - 1];

	public function new(externals:Null<Map<String, {arguments:Array<CompilerType>, result:CompilerType}>>,
			specializations:Null<GenericSpecializationRegistry>) {
		this.externals = externals == null ? [] : externals;
		this.genericSpecializations = specializations == null ? new GenericSpecializationRegistry() : specializations;
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
