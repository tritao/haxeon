package compiler;

import compiler.syntax.Ast.AstFunction;
import compiler.runtime.NativeRegistry.NativeDefinition;
import compiler.abi.RuntimeAbi.RuntimeAbiDescriptor;
import compiler.hl.incremental.HlModuleAssembler;
import compiler.ir.Ir.IrNative;
import compiler.ir.Ir.IrObject;
import compiler.ir.Ir.IrProgram;
import compiler.modules.ModuleGraph;
import compiler.modules.ModuleState;
import compiler.semantic.ModuleAnalyzer;
import compiler.semantic.GenericSpecializationRegistry;
import compiler.semantic.SemanticProgram;
import compiler.semantic.SemanticIndex.SemanticSymbolId;
import compiler.types.Type.CompilerType;
import compiler.types.TypedAst.TypedProgram;
import haxe.io.Bytes;

/** Narrow, typed access to mutable state needed while building a candidate. */
class CompilationContext {
	final owner:Compiler;
	final moduleAnalyzer:ModuleAnalyzer;

	public final modules:Map<String, ModuleState>;
	public final graph:ModuleGraph;
	public final objectCache:Map<String, IrObject>;
	public final moduleId:Bytes;
	public final genericSpecializations:GenericSpecializationRegistry;

	public var assembler(get, set):HlModuleAssembler;
	public var publishedAbi(get, set):Null<RuntimeAbiDescriptor>;
	public var compiledOnce(get, set):Bool;
	public var cachedSemanticProgram(get, set):Null<SemanticProgram>;

	public function new(owner:Compiler) {
		this.owner = owner;
		modules = owner.modules;
		graph = owner.graph;
		objectCache = owner.objectCache;
		moduleId = owner.moduleId;
		genericSpecializations = owner.genericSpecializations;
		moduleAnalyzer = new ModuleAnalyzer(modules, owner.types, owner.natives, owner.compiledOnce, owner.defines);
	}

	public function writableState(name:String, rollback:Map<String, ModuleState>):ModuleState
		return owner.writableState(name, rollback);

	public function parse(state:ModuleState, entry:String, body:Map<String, Bool>, signatures:Map<String, Bool>, structural:Map<String, Bool>):Void
		moduleAnalyzer.parse(state, entry, body, signatures, structural);

	public function addTypeDependencies(state:ModuleState):Void
		moduleAnalyzer.addTypeDependencies(state);

	public function importAliases(imports:Array<String>, explicit:Map<String, String>):Map<String, String>
		return moduleAnalyzer.importAliases(imports, explicit);

	public function executableEntryPoint(entry:String):String
		return owner.executableEntryPoint(entry);

	public function nativeSignatures():Map<String, {arguments:Array<CompilerType>, result:CompilerType}>
		return owner.nativeSignatures();

	public function resolveSemanticSymbol(name:String):Null<SemanticSymbolId>
		return owner.semanticWorkspace.resolveSymbolId(name);

	public function resolveSemanticEnumCase(name:String, index:Int):Null<SemanticSymbolId>
		return owner.semanticWorkspace.resolveEnumCaseId(name, index);

	public function resolveSemanticType(name:String):Null<SemanticSymbolId>
		return owner.semanticWorkspace.resolveTypeSymbolId(name);

	public function irNatives():Array<IrNative>
		return owner.irNatives();

	public function rehydratedChanges(regenerated:Array<String>, program:IrProgram):Array<String>
		return owner.rehydratedChanges(regenerated, program);

	public function stableIdsBySlot(source:HlModuleAssembler, layout:Map<String, Int>):Map<Int, Int>
		return owner.stableIdsBySlot(source, layout);

	public function setLastTypedProgram(value:TypedProgram):Void
		owner.lastTypedProgram = value;

	public function clearRehydrationBaseline():Void
		owner.rehydrationBaseline = null;

	public static function mapIsEmpty(values:Map<String, Bool>):Bool
		return Compiler.mapIsEmpty(values);

	public static function explicitFunctionSignatures(functions:Array<AstFunction>):Bool
		return Compiler.explicitFunctionSignatures(functions);

	public static function copyIndices(source:Map<String, Int>):Map<String, Int>
		return Compiler.copyIndices(source);

	function get_assembler():HlModuleAssembler
		return owner.assembler;

	function set_assembler(value:HlModuleAssembler):HlModuleAssembler {
		owner.assembler = value;
		return value;
	}

	function get_publishedAbi():Null<RuntimeAbiDescriptor>
		return owner.publishedAbi;

	function set_publishedAbi(value:Null<RuntimeAbiDescriptor>):Null<RuntimeAbiDescriptor> {
		owner.publishedAbi = value;
		return value;
	}

	function get_compiledOnce():Bool
		return owner.compiledOnce;

	function set_compiledOnce(value:Bool):Bool {
		owner.compiledOnce = value;
		return value;
	}

	function get_cachedSemanticProgram():Null<SemanticProgram>
		return owner.cachedSemanticProgram;

	function set_cachedSemanticProgram(value:Null<SemanticProgram>):Null<SemanticProgram> {
		owner.cachedSemanticProgram = value;
		return value;
	}
}
