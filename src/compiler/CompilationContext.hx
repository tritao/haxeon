package compiler;

import compiler.syntax.Ast.AstFunction;
import compiler.abi.NativeRegistry.NativeDefinition;
import compiler.abi.RuntimeAbi.RuntimeAbiDescriptor;
import compiler.hl.incremental.HlModuleAssembler;
import compiler.ir.Ir.IrNative;
import compiler.ir.Ir.IrObject;
import compiler.ir.Ir.IrProgram;
import compiler.modules.ModuleGraph;
import compiler.modules.ModuleState;
import compiler.semantic.ModuleAnalyzer;
import compiler.semantic.GenericSpecializationRegistry;
import compiler.types.SemanticProgram;
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
		moduleAnalyzer = new ModuleAnalyzer(modules, owner.types, owner.natives, owner.compiledOnce);
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

	function get_assembler()
		return owner.assembler;

	function set_assembler(value)
		return owner.assembler = value;

	function get_publishedAbi()
		return owner.publishedAbi;

	function set_publishedAbi(value)
		return owner.publishedAbi = value;

	function get_compiledOnce()
		return owner.compiledOnce;

	function set_compiledOnce(value)
		return owner.compiledOnce = value;

	function get_cachedSemanticProgram()
		return owner.cachedSemanticProgram;

	function set_cachedSemanticProgram(value)
		return owner.cachedSemanticProgram = value;
}
