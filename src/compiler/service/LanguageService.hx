package compiler.service;

import compiler.semantic.ModuleCanonicalizer;
import compiler.syntax.Ast.AstType;
import compiler.syntax.Ast.AstProgram;
import compiler.Diagnostic;
import compiler.Source.SourceFile;
import compiler.Source.SourceSpan;
import compiler.syntax.Token.TokenKind;
import compiler.Compiler;
import compiler.modules.ModulePath;
import compiler.modules.ModuleState;
import compiler.semantic.SemanticIndex.SemanticSymbolId;
import compiler.semantic.SemanticIndex.SemanticCompletionContext;
import compiler.semantic.SemanticIndex.SemanticCompletionContextKind;
import compiler.semantic.SemanticIndex.UnresolvedSymbol;
import compiler.semantic.SemanticModel;
import compiler.Compiler.CompileResult;
import compiler.types.Type.CompilerType;
import compiler.types.Type.NominalKind;
import compiler.types.DeclarationIndex.DeclarationKind;
import compiler.types.DeclarationIndex;
import compiler.types.TypeRelations;
import compiler.types.Typer;
import compiler.types.Typer.RecoveryTypingModule;
import compiler.types.SignatureInference;
import compiler.service.EditorSnapshot.EditorSnapshot;
import compiler.service.EditorSnapshot.EditorSnapshotConfidence;
import compiler.runtime.CompilerIntrinsics;
import compiler.syntax.Lexer;
import compiler.syntax.Parser;
import compiler.syntax.ConditionalCompilation;
import compiler.syntax.ConditionalCompilation.ConditionalSource;
import compiler.Diagnostic.CompileError;
import compiler.Diagnostic.DiagnosticSeverity;
import compiler.Diagnostic.DiagnosticOrigin;
import compiler.documentation.Documentation;
import compiler.documentation.Documentation.DocumentationTools;
import compiler.documentation.Documentation.DocumentationComment;

/** Editor-facing declaration summary, optionally marked as stale. */
typedef DocumentSymbol = {
	final ?revision:Int;
	final ?stale:Bool;
	final name:String;
	final kind:String;
	final detail:String;
	final span:SourceSpan;
}

/** Editor completion candidate derived from the effective compiler snapshot. */
typedef CompletionItem = {
	final ?revision:Int;
	final ?stale:Bool;
	final label:String;
	final kind:String;
	final detail:String;
	final ?sortText:String;
	final ?insertText:String;
	final ?identity:String;
	final ?importPath:String;
}

typedef ResolvedCompletion = {
	final detail:String;
	final documentation:String;
	final edits:Array<TextEdit>;
}

typedef SymbolDocumentation = Documentation;

typedef CompletionResult = {
	final items:Array<CompletionItem>;
	final isIncomplete:Bool;
}

/** Compiler-owned completion context selected from one editor snapshot. */
typedef EditorCompletionContext = {
	final context:SemanticCompletionContext;
	final revision:Int;
	final stale:Bool;
	final recovered:Bool;
	final confidence:EditorSnapshotConfidence;
}

/** A same-document semantic occurrence, classified for LSP highlighting. */
typedef DocumentHighlight = {
	final span:SourceSpan;
	final write:Bool;
}

/** Absolute semantic token; transport adapters own position/delta encoding. */
typedef SemanticToken = {
	final span:SourceSpan;
	final type:String;
	final modifiers:Array<String>;
}

typedef CodeAction = {
	final id:String;
	final title:String;
	final diagnostic:Diagnostic;
	final edits:Array<TextEdit>;
}

typedef WorkspaceSymbol = {
	final identity:String;
	final name:String;
	final kind:String;
	final ?container:String;
	final detail:String;
	final path:String;
	final span:SourceSpan;
	final revision:Int;
	final ?documentation:String;
	final ?deprecated:Bool;
}

typedef InlayHint = {
	final position:Int;
	final label:String;
	final kind:String;
	final paddingLeft:Bool;
	final paddingRight:Bool;
}

typedef CallHierarchyItem = {
	final identity:String;
	final name:String;
	final kind:String;
	final detail:String;
	final path:String;
	final span:SourceSpan;
	final revision:Int;
	final ?documentation:String;
}

typedef CallHierarchyRelation = {
	final item:CallHierarchyItem;
	final ranges:Array<SourceSpan>;
}

typedef TypeHierarchyItem = {
	final identity:String;
	final name:String;
	final kind:String;
	final detail:String;
	final path:String;
	final span:SourceSpan;
	final revision:Int;
}

typedef FoldingRegion = {
	final span:SourceSpan;
	final ?kind:String;
}

typedef DocumentLink = {
	final span:SourceSpan;
	final targetPath:String;
	final tooltip:String;
}

private typedef StructuralIndexEntry = {
	final revision:Int;
	final folds:Array<FoldingRegion>;
	final containers:Array<SourceSpan>;
}

private typedef WorkspaceIndexEntry = {
	final revision:Int;
	final symbols:Array<WorkspaceSymbol>;
}

private typedef DocumentationIndexEntry = {
	final revision:Int;
	final comments:Array<DocumentationComment>;
}

private typedef RecoveredCompletionCandidate = {
	final kind:String;
	final detail:String;
	final insertText:Null<String>;
	final importPath:String;
}

/** Source location returned by a semantic navigation query. */
typedef SymbolLocation = {
	final ?revision:Int;
	final ?stale:Bool;
	final path:String;
	final span:SourceSpan;
}

/** Revision-aware source replacement proposed by an editor operation. */
typedef TextEdit = {
	final ?revision:Int;
	final ?stale:Bool;
	final path:String;
	final span:SourceSpan;
	final replacement:String;
}

typedef SignatureHelp = {
	final label:String;
	final parameters:Array<String>;
	final activeParameter:Int;
	final ?revision:Int;
	final ?stale:Bool;
	final ?documentation:String;
	final ?parameterDocumentation:Array<Null<String>>;
}

private typedef SemanticQueryContext = {
	final state:ModuleState;
	final snapshot:EditorSnapshot;
	final model:SemanticModel;
	final symbol:Null<SemanticSymbolId>;
	final completion:SemanticCompletionContext;
	final stale:Bool;
	final confidence:EditorSnapshotConfidence;
}

/** Read-only editor queries backed by the persistent compiler state. */
class LanguageService {
	static inline final MAX_COMPLETION_ITEMS = 200;
	static inline final MAX_REFERENCE_RESULTS = 10000;

	public final compiler:Compiler;
	public var recoveredSnapshotBuilds(default, null):Int = 0;

	final workspaceIndex:Map<String, WorkspaceIndexEntry> = [];
	final documentationIndex:Map<String, DocumentationIndexEntry> = [];
	final structuralIndex:Map<String, StructuralIndexEntry> = [];
	final recoveredCompletionPrograms:Map<String, {revision:Int, program:AstProgram}> = [];
	var editorDefines:Map<String, String> = [];
	var editorScopeIdentity = "default";

	public function new(?identityState:haxe.io.Bytes) {
		compiler = new Compiler(identityState, CompilerIntrinsics.configuration());
		compiler.addSourceRoot("stdlib");
	}

	public function update(path:String, source:String):ModuleState {
		var moduleName = ModulePath.fromFile(path),
			previous = compiler.modules.get(moduleName),
			previousRevision = previous == null ? 0 : previous.revision,
			state = compiler.update(path, source),
			changed = state.revision != previousRevision;
		compiler.semanticWorkspace.invalidateResolutionCache();
		if (state.ast == null && (state.recoveredSemanticModel == null || state.recoveredSemanticModel.revision != state.revision))
			recoverSyntax(state);
		if (changed)
			refreshDependentRecovery(state);
		compiler.semanticWorkspace.invalidateResolutionCache();
		return state;
	}

	public function remove(path:String):Bool {
		var name = ModulePath.fromFile(path), removed = compiler.remove(path);
		if (!removed)
			return false;
		workspaceIndex.remove(name);
		documentationIndex.remove(name);
		structuralIndex.remove(name);
		recoveredCompletionPrograms.remove(name);
		compiler.semanticWorkspace.invalidateResolutionCache();
		refreshAllRecovery();
		return true;
	}

	public function configure(identity:String, scopeIdentity:String, defines:Array<String>):Void {
		var nextDefines:Map<String, String> = [];
		for (define in defines) {
			var separator = define.indexOf("="),
				name = separator < 0 ? define : define.substr(0, separator);
			nextDefines.set(name, separator < 0 ? "1" : define.substr(separator + 1));
		}
		if (identity == compiler.configurationIdentity
			&& scopeIdentity == editorScopeIdentity
			&& sameDefines(editorDefines, nextDefines))
			return;
		editorDefines = nextDefines;
		editorScopeIdentity = scopeIdentity;
		workspaceIndex.clear();
		documentationIndex.clear();
		structuralIndex.clear();
		recoveredCompletionPrograms.clear();
		compiler.configure(identity, scopeIdentity, defines);
	}

	static function sameDefines(left:Map<String, String>, right:Map<String, String>):Bool {
		var leftCount = 0;
		for (name => value in left) {
			leftCount++;
			if (!right.exists(name) || right.get(name) != value)
				return false;
		}
		var rightCount = 0;
		for (_ in right)
			rightCount++;
		return leftCount == rightCount;
	}

	public function compile(entryModule:String, ?token:CancellationToken):CompileResult
		return compiler.compile(entryModule, token);

	public function analyze(entryModule:String, ?token:CancellationToken):compiler.Compiler.AnalysisResult {
		try
			return compiler.analyze(entryModule, token)
		catch (error:CompileError) {
			recoverCurrentSyntax(token);
			throw error;
		}
	}

	function recoverCurrentSyntax(?token:CancellationToken):Void {
		for (state in compiler.modules) {
			if (state.ast != null)
				continue;
			if (state.recoveredSemanticModel != null && state.recoveredSemanticModel.revision == state.revision) {
				mergeRecoveryDiagnostics(state, state.recoveryDiagnostics);
				continue;
			}
			recoverSyntax(state, token);
		}
		compiler.semanticWorkspace.invalidateResolutionCache();
	}

	function recoverSyntax(state:ModuleState, ?token:CancellationToken):Void {
		if (token != null)
			token.check();
		state.recoveryDiagnostics = [];
		var conditional:ConditionalSource;
		try
			conditional = ConditionalCompilation.process(state.source, editorDefines)
		catch (error:CompileError) {
			state.conditionalDefines = [];
			error.diagnostic.origin = DiagnosticOrigin.ParserRecovery;
			publishRecoveryDiagnostics(state, [error.diagnostic]);
			return;
		}
		state.conditionalDefines = conditional.defines;
		var checkpoint:Null<Void->Void> = token == null ? null : function() token.check(),
			tokens:Array<compiler.syntax.Token>;
		try
			tokens = new Lexer(state.source, conditional.text, checkpoint).tokenize()
		catch (error:CompileError) {
			error.diagnostic.origin = DiagnosticOrigin.Lexical;
			publishRecoveryDiagnostics(state, [error.diagnostic]);
			return;
		}
		try {
			var recovered = new Parser(tokens, checkpoint).parseProgramRecovering();
			var recoveredModel = new SemanticModel(recovered.program, state.source, state.revision, tokens),
				typingDiagnostics:Array<Diagnostic> = [],
				typingModules = recoveryTypingModules(state, recovered.program, token);
			recoveredModel.partialTypedProgram = Typer.typeRecovered(recovered.program, null, checkpoint, typingDiagnostics, typingModules);
			for (module in typingModules)
				recoveredModel.index.indexRecoveredModule(module.program, module.declarations, module.qualifiers, token);
			recoveredModel.index.indexRecoveredSyntax(recovered.program, token, recoveredModel.partialTypedProgram,
				function(name) return resolveRecoveredSymbol(recovered.program, name),
				function(name, index) return resolveRecoveredEnumCase(recovered.program, name, index),
				function(name, arguments) return resolveRecoveredType(recovered.program, name, arguments));
			state.recoveredTokens = tokens;
			state.recoveredAst = recovered.program;
			state.recoveredSemanticModel = recoveredModel;
			recoveredSnapshotBuilds++;
			publishRecoveryDiagnostics(state, recovered.diagnostics.concat(typingDiagnostics));
		} catch (error:CompileError) {
			error.diagnostic.origin = DiagnosticOrigin.ParserRecovery;
			// Parser recovery itself failed. Keep the last-good semantic snapshot
			// available; do not destroy it.
			publishRecoveryDiagnostics(state, [error.diagnostic]);
		} catch (error:Dynamic) {
			if (Std.isOfType(error, CancellationError))
				throw error;
			// Unexpected recovery failures must not escape an editor update. Keep
			// the last-good semantic snapshot and expose one bounded diagnostic.
			publishRecoveryDiagnostics(state, [
				new Diagnostic("E0002", "Unable to recover editor syntax", state.source.span(0, 0), DiagnosticSeverity.Error, null,
					DiagnosticOrigin.ParserRecovery)
			]);
		}
	}

	/**
	 * Rebuild recovered snapshots that import or share a package with a changed
	 * editor module. Valid compiler snapshots remain authoritative and are left
	 * for normal analysis invalidation.
	 */
	function refreshDependentRecovery(changed:ModuleState):Void {
		var pending:Array<ModuleState> = [changed],
			refreshed:Map<String, Bool> = [changed.name => true],
			pendingIndex = 0;
		while (pendingIndex < pending.length) {
			var dependency = pending[pendingIndex++],
				dependencyProgram = effectiveAst(dependency);
			if (dependencyProgram == null)
				continue;
			for (candidate in compiler.modules) {
				if (candidate == dependency || candidate.ast != null || refreshed.exists(candidate.name))
					continue;
				var candidateProgram = effectiveAst(candidate);
				if (candidateProgram == null || !recoveryModuleVisible(candidateProgram, dependency, dependencyProgram))
					continue;
				clearRecoveredSnapshot(candidate);
				recoverSyntax(candidate);
				refreshed.set(candidate.name, true);
				pending.push(candidate);
			}
		}
	}

	/** Rebuild all non-valid snapshots after a module disappears from the workspace. */
	function refreshAllRecovery():Void {
		var pending:Array<ModuleState> = [for (state in compiler.modules) if (state.ast == null) state],
			oldPrograms:Map<String, AstProgram> = [];
		for (state in pending) {
			var program = effectiveAst(state);
			if (program != null)
				oldPrograms.set(state.name, program);
		}
		while (pending.length > 0) {
			var progressed = false, index = 0;
			while (index < pending.length) {
				var state = pending[index],
					program = oldPrograms.get(state.name),
					waitsForDependency = false;
				if (program != null)
					for (dependency in pending)
						if (dependency != state && oldPrograms.exists(dependency.name)
							&& recoveryModuleVisible(program, dependency, oldPrograms.get(dependency.name))) {
							waitsForDependency = true;
							break;
						}
				if (waitsForDependency) {
					index++;
					continue;
				}
				clearRecoveredSnapshot(state);
				recoverSyntax(state);
				pending.splice(index, 1);
				progressed = true;
			}
			if (!progressed) {
				var state = pending.shift();
				clearRecoveredSnapshot(state);
				recoverSyntax(state);
			}
		}
		compiler.semanticWorkspace.invalidateResolutionCache();
	}

	function clearRecoveredSnapshot(state:ModuleState):Void {
		for (previous in state.recoveryDiagnostics) {
			for (index in 0...state.diagnostics.length)
				if (sameDiagnostic(state.diagnostics[index], previous)) {
					state.diagnostics.splice(index, 1);
					break;
				}
		}
		state.recoveryDiagnostics = [];
		state.recoveredAst = null;
		state.recoveredTokens = [];
		state.recoveredSemanticModel = null;
	}

	static function sameDiagnostic(left:Diagnostic, right:Diagnostic):Bool
		return left.code == right.code
			&& left.message == right.message
			&& left.span.file.path == right.span.file.path
			&& left.span.start == right.span.start
			&& left.span.end == right.span.end;

	/**
	 * Supply tolerant typing with declarations from modules already known to the
	 * editor. These declarations are copied into the temporary semantic program
	 * only; the authoritative workspace index remains unchanged.
	 */
	function recoveryTypingModules(state:ModuleState, program:AstProgram, ?token:CancellationToken):Array<RecoveryTypingModule> {
		var result:Array<RecoveryTypingModule> = [],
			pending:Array<ModuleState> = [],
			queued:Map<String, Bool> = [];
		for (candidate in compiler.modules) {
			if (token != null)
				token.check();
			var model = effectiveSemanticModel(candidate);
			if (candidate == state
				|| model == null
				|| !recoveryModuleVisible(program, candidate, model.program)
				|| queued.exists(candidate.name))
				continue;
			queued.set(candidate.name, true);
			pending.push(candidate);
		}
		var pendingIndex = 0;
		while (pendingIndex < pending.length) {
			if (token != null)
				token.check();
			var candidate = pending[pendingIndex++],
				model = effectiveSemanticModel(candidate);
			if (model == null)
				continue;
			var recoveredProgram = SignatureInference.inferProgram(model.program);
			result.push({
				program: recoveredProgram,
				declarations: DeclarationIndex.forModule(recoveredProgram, candidate.source),
				qualifiers: recoveryModuleQualifiers(program, candidate, recoveredProgram)
			});
			for (nested in compiler.modules) {
				if (token != null)
					token.check();
				if (nested == state || queued.exists(nested.name))
					continue;
				var nestedModel = effectiveSemanticModel(nested);
				if (nestedModel == null || !recoveryModuleVisible(model.program, nested, nestedModel.program))
					continue;
				queued.set(nested.name, true);
				pending.push(nested);
			}
		}
		return result;
	}

	static function recoveryModuleVisible(program:AstProgram, candidate:ModuleState, candidateProgram:AstProgram):Bool {
		if (program.packageName != null && program.packageName == candidateProgram.packageName)
			return true;
		for (importPath in program.imports)
			if (modulePathMatches(candidate.name, importPath))
				return true;
		for (_ => importPath in program.importAliases)
			if (modulePathMatches(candidate.name, importPath))
				return true;
		return false;
	}

	static function recoveryModuleQualifiers(program:AstProgram, candidate:ModuleState, candidateProgram:AstProgram):Array<String> {
		var result:Array<String> = [], add = function(value:String):Void {
			if (value.length > 0 && result.indexOf(value) < 0)
				result.push(value);
		};
		add(sourceName(candidate.name));
		add(candidate.name);
		if (candidateProgram.packageName != null)
			add(candidateProgram.packageName);
		for (importPath in program.imports)
			if (modulePathMatches(candidate.name, importPath))
				add(importQualifier(program, importPath));
		for (alias => importPath in program.importAliases)
			if (modulePathMatches(candidate.name, importPath))
				add(alias);
		return result;
	}

	static function modulePathMatches(moduleName:String, importPath:String):Bool {
		if (moduleName == importPath)
			return true;
		var wildcard = importPath.length > 2 && StringTools.endsWith(importPath, ".*");
		if (wildcard)
			return StringTools.startsWith(moduleName, importPath.substr(0, importPath.length - 2) + ".");
		return StringTools.startsWith(importPath, moduleName + ".") || StringTools.startsWith(moduleName, importPath + ".");
	}

	function publishRecoveryDiagnostics(state:ModuleState, diagnostics:Array<Diagnostic>):Void {
		state.recoveryDiagnostics = diagnostics.copy();
		mergeRecoveryDiagnostics(state, state.recoveryDiagnostics);
	}

	function mergeRecoveryDiagnostics(state:ModuleState, diagnostics:Array<Diagnostic>):Void {
		for (diagnostic in diagnostics) {
			var duplicate = -1;
			for (index in 0...state.diagnostics.length) {
				var existing = state.diagnostics[index];
				if (existing.span.start == diagnostic.span.start && existing.message == diagnostic.message) {
					duplicate = index;
					break;
				}
			}
			if (duplicate < 0)
				state.diagnostics.push(diagnostic);
			else {
				var existing = state.diagnostics[duplicate];
				if (existing.fixes.length == 0 && diagnostic.fixes.length > 0)
					state.diagnostics[duplicate] = diagnostic;
				else if (existing.origin == DiagnosticOrigin.Semantic && diagnostic.origin == DiagnosticOrigin.ParserRecovery)
					existing.origin = diagnostic.origin;
			}
		}
	}

	function resolveRecoveredSymbol(program:AstProgram, name:String):Null<SemanticSymbolId> {
		var qualifiedName = packageQualifiedName(program, name),
			direct = compiler.semanticWorkspace.resolveSymbolId(name);
		if (direct == null && qualifiedName != name)
			direct = compiler.semanticWorkspace.resolveSymbolId(qualifiedName);
		if (direct != null)
			return direct;
		var separator = name.indexOf(".");
		if (separator < 1) {
			for (importPath in program.imports)
				if (importQualifier(program, importPath) == name) {
					var importedType = compiler.semanticWorkspace.resolveSymbolId(importPath);
					if (importedType != null)
						return importedType;
				}
			return null;
		}
		var qualifier = name.substring(0, separator),
			suffix = name.substring(separator + 1, name.length);
		for (importPath in program.imports) {
			if (importQualifier(program, importPath) == qualifier) {
				var imported = compiler.semanticWorkspace.resolveSymbolId(importPath + "." + suffix);
				if (imported == null)
					imported = compiler.semanticWorkspace.memberSymbolId(TInstance(NominalKind.Class, importPath, []), suffix);
				if (imported != null)
					return imported;
			}
		}
		if (program.packageName != null && program.packageName.length > 0) {
			var packageOwner = program.packageName + "." + qualifier,
				packageMember = compiler.semanticWorkspace.resolveSymbolId(packageOwner + "." + suffix);
			if (packageMember == null)
				packageMember = compiler.semanticWorkspace.memberSymbolId(TInstance(NominalKind.Class, packageOwner, []), suffix);
			if (packageMember != null)
				return packageMember;
		}
		return null;
	}

	function resolveRecoveredEnumCase(program:AstProgram, name:String, index:Int):Null<SemanticSymbolId> {
		var direct = compiler.semanticWorkspace.resolveEnumCaseId(name, index);
		if (direct != null)
			return direct;
		for (importPath in program.imports) {
			if (importQualifier(program, importPath) == name) {
				var imported = compiler.semanticWorkspace.resolveEnumCaseId(importPath, index);
				if (imported != null)
					return imported;
			}
		}
		return null;
	}

	function resolveRecoveredType(program:AstProgram, name:String, arguments:Array<CompilerType>):Null<CompilerType> {
		var qualifiedName = packageQualifiedName(program, name),
			direct = compiler.semanticWorkspace.resolveTypeSymbolId(name);
		if (direct == null && qualifiedName != name)
			direct = compiler.semanticWorkspace.resolveTypeSymbolId(qualifiedName);
		if (direct != null)
			return recoveredTypeForIdentity(direct, name, arguments);
		for (importPath in program.imports) {
			if (importQualifier(program, importPath) != name)
				continue;
			var imported = importedModule(importPath),
				importedAst = imported == null ? null : effectiveAst(imported);
			if (importedAst == null)
				continue;
			for (decl in importedAst.classes)
				if (decl.name == sourceName(importPath))
					return TInstance(NominalKind.Class, decl.name, arguments);
			for (decl in importedAst.interfaces)
				if (decl.name == sourceName(importPath))
					return TInstance(NominalKind.Interface, decl.name, arguments);
			for (decl in importedAst.enums)
				if (decl.name == sourceName(importPath))
					return TInstance(NominalKind.Enum, decl.name, arguments);
		}
		if (program.packageName != null && program.packageName.length > 0)
			for (candidate in compiler.modules) {
				var candidateAst = effectiveAst(candidate);
				if (candidateAst == null || candidateAst.packageName != program.packageName)
					continue;
				for (decl in candidateAst.classes)
					if (decl.name == name)
						return TInstance(NominalKind.Class, name, arguments);
				for (decl in candidateAst.interfaces)
					if (decl.name == name)
						return TInstance(NominalKind.Interface, name, arguments);
				for (decl in candidateAst.enums)
					if (decl.name == name)
						return TInstance(NominalKind.Enum, name, arguments);
			}
		return null;
	}

	static function packageQualifiedName(program:AstProgram, name:String):String {
		var packageName = program.packageName;
		return name.indexOf(".") < 0 && packageName != null && packageName.length > 0 ? packageName + "." + name : name;
	}

	function recoveredTypeForIdentity(id:SemanticSymbolId, name:String, arguments:Array<CompilerType>):CompilerType {
		var identity = Std.string(id);
		return if (identity.indexOf(":class:") >= 0) TInstance(NominalKind.Class, name,
			arguments); else if (identity.indexOf(":interface:") >= 0) TInstance(NominalKind.Interface, name,
			arguments); else if (identity.indexOf(":enum:") >= 0) TInstance(NominalKind.Enum, name, arguments); else TUnknown;
	}

	public function validate(path:String, source:String, entryModule:String, ?token:CancellationToken):compiler.Compiler.ValidationResult
		return compiler.validate(path, source, entryModule, token);

	public function diagnostics(path:String):Array<Diagnostic> {
		var state = stateFor(path);
		return state == null ? [] : state.diagnostics.copy();
	}

	/** Return unresolved names recorded by the effective editor snapshot. */
	public function unresolvedSymbols(path:String, ?token:CancellationToken):Array<UnresolvedSymbol> {
		var state = stateFor(path),
			model = state == null ? null : effectiveSemanticModel(state);
		if (model == null)
			return [];
		var result = model.index.unresolvedSymbols();
		if (token != null)
			for (_ in result)
				token.check();
		return result;
	}

	/** Return the unresolved fact covering a source position, if any. */
	public function unresolvedSymbolAt(path:String, position:Int, ?token:CancellationToken):Null<UnresolvedSymbol> {
		var state = stateFor(path),
			model = state == null ? null : effectiveSemanticModel(state);
		if (model == null)
			return null;
		if (token != null)
			token.check();
		return model.index.unresolvedAt(position);
	}

	public function codeActions(path:String, start:Int, end:Int):Array<CodeAction> {
		var state = stateFor(path), result:Array<CodeAction> = [];
		if (state == null)
			return result;
		for (diagnostic in state.diagnostics) {
			if (diagnostic.span.end < start || diagnostic.span.start > end)
				continue;
			for (fix in diagnostic.fixes)
				result.push({
					id: diagnostic.code + ":" + fix.id,
					title: fix.title,
					diagnostic: diagnostic,
					edits: [
						for (edit in fix.edits)
							{
								path: edit.span.file.path,
								span: edit.span,
								replacement: edit.replacement,
								revision: state.revision,
								stale: false
							}
					]
				});
		}
		return result;
	}

	public function workspaceSymbols(query:String, ?token:CancellationToken):Array<WorkspaceSymbol> {
		var normalized = query.toLowerCase(),
			result:Array<WorkspaceSymbol> = [];
		for (state in compiler.modules) {
			if (token != null)
				token.check();
			for (symbol in indexedWorkspaceSymbols(state, token))
				if (normalized.length == 0 || symbol.name.toLowerCase().indexOf(normalized) >= 0)
					result.push(symbol);
		}
		result.sort(function(left, right) {
			var leftPrefix = StringTools.startsWith(left.name.toLowerCase(), normalized),
				rightPrefix = StringTools.startsWith(right.name.toLowerCase(), normalized);
			if (leftPrefix != rightPrefix)
				return leftPrefix ? -1 : 1;
			var name = Reflect.compare(left.name, right.name);
			return name == 0 ? Reflect.compare(left.identity, right.identity) : name;
		});
		return result.length > 200 ? result.slice(0, 200) : result;
	}

	public function resolveWorkspaceSymbol(identity:String, revision:Int):Null<WorkspaceSymbol> {
		for (state in compiler.modules)
			if (state.revision == revision)
				for (symbol in indexedWorkspaceSymbols(state))
					if (symbol.identity == identity)
						return symbol;
		return null;
	}

	public function inlayHints(path:String, start:Int, end:Int, ?token:CancellationToken):Array<InlayHint> {
		var state = stateFor(path),
			snapshot = state == null ? null : editorSnapshot(state),
			model = snapshot == null ? null : snapshot.semanticModel,
			tokens = snapshot == null ? null : snapshot.tokens,
			result:Array<InlayHint> = [];
		if (state == null || model == null || tokens == null)
			return result;
		for (index in 0...tokens.length) {
			if (token != null)
				token.check();
			var current = tokens[index];
			if (current.span.start > end)
				break;
			if (current.kind == Var && index + 1 < tokens.length && tokens[index + 1].kind == Identifier) {
				var name = tokens[index + 1],
					after = index + 2 < tokens.length ? tokens[index + 2] : null;
				if (name.span.end >= start && name.span.end <= end && (after == null || after.kind != Colon)) {
					var context = model.index.completionContext(name.span.end, null, token),
						localType:Null<CompilerType> = null;
					for (local in context.locals)
						if (local.name == name.text)
							localType = local.type;
					if (localType != null)
						result.push({
							position: name.span.end,
							label: ": " + compilerTypeName(localType),
							kind: "type",
							paddingLeft: false,
							paddingRight: false
						});
				}
			}
			if (current.kind == LeftParen && index > 0 && (tokens[index - 1].kind == Identifier || tokens[index - 1].kind == New))
				addParameterHints(path, tokens, index, start, end, result, token);
		}
		result.sort(function(left, right) return Reflect.compare(left.position, right.position));
		return result;
	}

	public function prepareCallHierarchy(path:String, position:Int, ?token:CancellationToken):Null<CallHierarchyItem> {
		if (token != null)
			token.check();
		var context = semanticQuery(path, position, null, token);
		if (context == null || context.symbol == null)
			return null;
		return callHierarchyItem(context.symbol);
	}

	public function incomingCalls(identity:String, revision:Int, ?token:CancellationToken):Array<CallHierarchyRelation>
		return hierarchyCalls(identity, revision, true, token);

	public function outgoingCalls(identity:String, revision:Int, ?token:CancellationToken):Array<CallHierarchyRelation>
		return hierarchyCalls(identity, revision, false, token);

	public function isCallHierarchyCurrent(identity:String, revision:Int):Bool {
		var item = callHierarchyItem(cast identity);
		return item != null && item.revision == revision;
	}

	public function prepareTypeHierarchy(path:String, position:Int, ?token:CancellationToken):Null<TypeHierarchyItem> {
		if (token != null)
			token.check();
		var context = semanticQuery(path, position, null, token);
		if (context == null || context.symbol == null)
			return null;
		return typeHierarchyItem(context.symbol);
	}

	public function typeSupertypes(identity:String, revision:Int, ?token:CancellationToken):Array<TypeHierarchyItem>
		return hierarchyTypes(identity, revision, true, token);

	public function typeSubtypes(identity:String, revision:Int, ?token:CancellationToken):Array<TypeHierarchyItem>
		return hierarchyTypes(identity, revision, false, token);

	public function isTypeHierarchyCurrent(identity:String, revision:Int):Bool {
		var item = typeHierarchyItem(cast identity);
		return item != null && item.revision == revision;
	}

	public function foldingRanges(path:String, ?token:CancellationToken):Array<FoldingRegion> {
		var state = stateFor(path);
		return state == null ? [] : indexedStructure(state, token).folds.copy();
	}

	public function format(path:String, start:Int, end:Int, tabSize:Int, insertSpaces:Bool):Array<TextEdit> {
		var state = stateFor(path);
		if (state == null || start < 0 || end < start || end > state.source.bytes.length || tabSize <= 0)
			return [];
		var source = state.source.text,
			formatted = SourceFormatter.format(source, tabSize, insertSpaces, state.source.stringOffsetForByteOffset(start),
				state.source.stringOffsetForByteOffset(end));
		if (formatted == null || formatted == source)
			return [];
		var prefix = 0, limit = Std.int(Math.min(source.length, formatted.length));
		while (prefix < limit && source.charCodeAt(prefix) == formatted.charCodeAt(prefix))
			prefix++;
		var sourceSuffix = source.length, formattedSuffix = formatted.length;
		while (sourceSuffix > prefix
			&& formattedSuffix > prefix
			&& source.charCodeAt(sourceSuffix - 1) == formatted.charCodeAt(formattedSuffix - 1)) {
			sourceSuffix--;
			formattedSuffix--;
		}
		return [
			{
				path: path,
				span: state.source.span(state.source.byteOffsetForStringOffset(prefix), state.source.byteOffsetForStringOffset(sourceSuffix)),
				replacement: formatted.substring(prefix, formattedSuffix),
				revision: state.revision,
				stale: false
			}
		];
	}

	public function selectionRanges(path:String, positions:Array<Int>, ?token:CancellationToken):Array<Array<SourceSpan>> {
		var state = stateFor(path), result:Array<Array<SourceSpan>> = [];
		if (state == null)
			return result;
		var structure = indexedStructure(state, token),
			tokens = effectiveTokens(state);
		for (position in positions) {
			if (token != null)
				token.check();
			var spans:Array<SourceSpan> = [];
			if (tokens != null) {
				for (token in tokens)
					if (token.kind != Eof && position >= token.span.start && position <= token.span.end) {
						spans.push(token.span);
						break;
					}
			}
			for (span in structure.containers)
				if (position >= span.start && position <= span.end)
					spans.push(span);
			spans.sort(function(left, right) return Reflect.compare(left.end - left.start, right.end - right.start));
			var unique:Array<SourceSpan> = [];
			for (span in spans)
				if (unique.length == 0 || unique[unique.length - 1].start != span.start || unique[unique.length - 1].end != span.end)
					unique.push(span);
			result.push(unique);
		}
		return result;
	}

	public function documentLinks(path:String, ?token:CancellationToken):Array<DocumentLink> {
		var state = stateFor(path),
			snapshot = state == null ? null : editorSnapshot(state),
			tokens = snapshot == null ? null : snapshot.tokens,
			result:Array<DocumentLink> = [];
		if (state == null || tokens == null)
			return result;
		var index = 0;
		while (index < tokens.length) {
			if (token != null)
				token.check();
			if (tokens[index].kind != Import) {
				index++;
				continue;
			}
			index++;
			if (index >= tokens.length || tokens[index].kind != Identifier)
				continue;
			var start = tokens[index].span.start,
				end = tokens[index].span.end,
				parts = [tokens[index].text];
			index++;
			while (index + 1 < tokens.length && tokens[index].kind == Dot && tokens[index + 1].kind == Identifier) {
				parts.push(tokens[index + 1].text);
				end = tokens[index + 1].span.end;
				index += 2;
			}
			var importPath = parts.join("."),
				target = importedModule(importPath);
			if (target != null)
				result.push({span: snapshot.source.span(start, end), targetPath: target.source.path, tooltip: "Open " + importPath});
		}
		return result;
	}

	function workspaceSymbolIdentity(identity:String):Null<WorkspaceSymbol> {
		for (state in compiler.modules)
			for (symbol in indexedWorkspaceSymbols(state))
				if (symbol.identity == identity)
					return symbol;
		return null;
	}

	function importedModule(importPath:String):Null<ModuleState> {
		var candidate = importPath;
		while (candidate.length > 0) {
			var state = compiler.modules.get(candidate);
			if (state != null)
				return state;
			var separator = candidate.lastIndexOf(".");
			if (separator < 0)
				break;
			candidate = candidate.substring(0, separator);
		}
		return null;
	}

	function callHierarchyItem(identity:SemanticSymbolId):Null<CallHierarchyItem> {
		var resolved = compiler.semanticWorkspace.indexedSymbol(identity);
		if (resolved == null)
			return null;
		var signature = compiler.semanticWorkspace.indexedSignature(identity),
			kind = switch resolved.symbol.kind {
				case DeclarationKind.Function: "function";
				case DeclarationKind.Class: "class";
				case DeclarationKind.Member if (signature != null): "method";
				default: return null;
			},
			documentation = documentationFor(resolved.state, resolved.symbol.declaration),
			detail = signature == null ? resolved.symbol.name : signature.label;
		if (documentation.markdown.length > 0)
			detail += " — " + documentation.markdown.split("\n")[0];
		return {
			identity: Std.string(identity),
			name: sourceName(resolved.symbol.name),
			kind: kind,
			detail: detail,
			path: resolved.state.source.path,
			span: resolved.symbol.declaration,
			revision: resolved.state.revision,
			documentation: documentation.markdown
		};
	}

	function hierarchyCalls(identity:String, revision:Int, incoming:Bool, ?token:CancellationToken):Array<CallHierarchyRelation> {
		var origin = callHierarchyItem(cast identity),
			grouped:Map<String, CallHierarchyRelation> = [];
		if (origin == null || origin.revision != revision)
			return [];
		for (located in compiler.semanticWorkspace.indexedCalls(token)) {
			var edge = located.edge,
				matches = incoming ? Std.string(edge.callee) == identity : Std.string(edge.caller) == identity;
			if (!matches)
				continue;
			var relatedId = incoming ? edge.caller : edge.callee,
				key = Std.string(relatedId),
				relation = grouped.get(key);
			if (relation == null) {
				var item = callHierarchyItem(relatedId);
				if (item == null)
					continue;
				grouped.set(key, relation = {item: item, ranges: []});
			}
			relation.ranges.push(edge.span);
		}
		var result = [for (relation in grouped) relation];
		result.sort(function(left, right) return Reflect.compare(left.item.identity, right.item.identity));
		for (relation in result)
			relation.ranges.sort(function(left, right) return Reflect.compare(left.start, right.start));
		return result;
	}

	function typeHierarchyItem(identity:SemanticSymbolId):Null<TypeHierarchyItem> {
		var resolved = compiler.semanticWorkspace.indexedSymbol(identity);
		if (resolved == null)
			return null;
		var kind = switch resolved.symbol.kind {
			case DeclarationKind.Class: "class";
			case DeclarationKind.Interface: "interface";
			default: return null;
		};
		return {
			identity: Std.string(identity),
			name: sourceName(resolved.symbol.name),
			kind: kind,
			detail: resolved.symbol.name,
			path: resolved.state.source.path,
			span: resolved.symbol.declaration,
			revision: resolved.state.revision
		};
	}

	function hierarchyTypes(identity:String, revision:Int, supertypes:Bool, ?token:CancellationToken):Array<TypeHierarchyItem> {
		var origin = typeHierarchyItem(cast identity);
		if (origin == null || origin.revision != revision)
			return [];
		var identities = supertypes ? compiler.semanticWorkspace.directTypeSupertypes(cast identity,
			token) : compiler.semanticWorkspace.directTypeSubtypes(cast identity, token),
			result:Array<TypeHierarchyItem> = [];
		for (related in identities) {
			var item = typeHierarchyItem(related);
			if (item != null)
				result.push(item);
		}
		result.sort(function(left, right) {
			var name = Reflect.compare(left.name, right.name);
			return name == 0 ? Reflect.compare(left.identity, right.identity) : name;
		});
		return result;
	}

	/** Whether editor spans and typed data belong to the latest source revision. */
	public function isCurrent(path:String):Bool {
		var state = stateFor(path);
		return state != null && state.ast != null && state.lastGoodRevision == state.revision;
	}

	/** Whether the latest source has either a valid or recovered editor snapshot. */
	public function isEditorSnapshotCurrent(path:String):Bool {
		var state = stateFor(path),
			snapshot = state == null ? null : editorSnapshot(state);
		return snapshot != null && !snapshot.stale;
	}

	public function editorSnapshotConfidence(path:String):Null<EditorSnapshotConfidence> {
		var state = stateFor(path),
			snapshot = state == null ? null : editorSnapshot(state);
		return snapshot == null ? null : snapshot.confidence;
	}

	public function documentSymbols(path:String, ?token:CancellationToken):Array<DocumentSymbol> {
		var state = stateFor(path),
			result:Array<DocumentSymbol> = [],
			ast = state == null ? null : effectiveAst(state);
		if (state == null || ast == null)
			return result;
		for (fn in ast.functions) {
			if (token != null)
				token.check();
			result.push({
				name: fn.name,
				kind: "function",
				detail: '${fn.name}():${typeName(fn.result)}',
				span: fn.span
			});
		}
		for (alias in ast.aliases) {
			if (token != null)
				token.check();
			result.push({
				name: alias.name,
				kind: "type",
				detail: 'typedef ${alias.name}${alias.typeParameters.length == 0 ? "" : "<" + alias.typeParameters.join(",") + ">"}=${typeName(alias.type)}',
				span: alias.span
			});
		}
		for (interfaceDecl in ast.interfaces) {
			if (token != null)
				token.check();
			result.push({
				name: interfaceDecl.name,
				kind: "interface",
				detail: 'interface ${interfaceDecl.name}',
				span: interfaceDecl.span
			});
			for (method in interfaceDecl.methods) {
				if (token != null)
					token.check();
				result.push({
					name: method.name,
					kind: "method",
					detail: '${method.name}():${typeName(method.result)}',
					span: method.span
				});
			}
		}
		for (enumDecl in ast.enums) {
			if (token != null)
				token.check();
			result.push({
				name: enumDecl.name,
				kind: "enum",
				detail: 'enum ${enumDecl.name}',
				span: enumDecl.span
			});
			for (caseDecl in enumDecl.cases) {
				if (token != null)
					token.check();
				result.push({
					name: caseDecl.name,
					kind: "enumCase",
					detail: '${enumDecl.name}.${caseDecl.name}(${[for (param in caseDecl.params) (param.optional ? "?" : "") + typeName(param.type)].join(",")})',
					span: caseDecl.span
				});
			}
		}
		for (classDecl in ast.classes) {
			if (token != null)
				token.check();
			result.push({
				name: classDecl.name,
				kind: "class",
				detail: 'class ${classDecl.name}',
				span: classDecl.span
			});
			for (field in classDecl.fields) {
				if (token != null)
					token.check();
				result.push({
					name: field.name,
					kind: "field",
					detail: '${field.name}:${typeName(field.type)}',
					span: field.span
				});
			}
			for (method in classDecl.methods) {
				if (token != null)
					token.check();
				result.push({
					name: method.name,
					kind: "method",
					detail: '${method.name}():${typeName(method.result)}',
					span: method.span
				});
			}
		}
		result.sort(function(a, b) return Reflect.compare(a.name, b.name));
		tagResults(result, state);
		return result;
	}

	public function complete(path:String, position:Int, ?token:CancellationToken):Array<CompletionItem>
		return completeResult(path, position, token).items;

	public function completionContext(path:String, position:Int, ?qualifier:String, ?token:CancellationToken):Null<EditorCompletionContext> {
		if (token != null)
			token.check();
		var state = stateFor(path),
			snapshot = state == null ? null : editorSnapshot(state),
			model = snapshot == null ? null : snapshot.semanticModel;
		if (state == null || snapshot == null || model == null)
			return null;
		var resolvedQualifier = qualifier == null ? memberQualifier(snapshot.source, position) : qualifier;
		return {
			context: model.index.completionContext(position, resolvedQualifier, token),
			revision: snapshot.revision,
			stale: snapshot.stale,
			recovered: snapshot.recovered,
			confidence: snapshot.confidence
		};
	}

	public function completeResult(path:String, position:Int, ?token:CancellationToken):CompletionResult {
		if (token != null)
			token.check();
		var state = stateFor(path),
			result:Array<CompletionItem> = [],
			snapshot = state == null ? null : editorSnapshot(state),
			ast = snapshot == null ? null : snapshot.ast;
		if (state == null || ast == null)
			return completionResult(result, state != null);
		var incompleteSnapshot = snapshot.recovered || snapshot.stale;
		var prefix = identifierPrefix(snapshot.source, position);
		var qualifier = memberQualifier(snapshot.source, position),
			model = snapshot.semanticModel,
			editorContext = completionContext(path, position, qualifier, token),
			semanticContext = editorContext == null ? null : editorContext.context;
		if (semanticContext != null && semanticContext.kind == SemanticCompletionContextKind.Override) {
			var owner = typeDeclaration(semanticContext.receiver);
			if (owner != null)
				for (symbol in compiler.semanticWorkspace.editorVisibleSymbols(state, token)) {
					if (token != null)
						token.check();
					var separator = symbol.name.lastIndexOf("."),
						signature = compiler.semanticWorkspace.editorSignature(state, symbol.id);
					if (symbol.kind == DeclarationKind.Member
						&& separator > 0
						&& symbol.name.substring(0, separator) == owner
						&& signature != null)
						addMember(sourceName(symbol.name), "method", signature.label, prefix, result, 0, sourceName(symbol.name) + "(", Std.string(symbol.id));
				}
			sortCompletion(result);
			tagResults(result, state);
			return completionResult(result, incompleteSnapshot);
		}
		if (semanticContext != null && semanticContext.kind == SemanticCompletionContextKind.Import) {
			for (candidate in compiler.semanticWorkspace.importableSymbols(state, token))
				addMember(candidate.symbol.name, completionDeclarationKind(candidate.symbol.kind), candidate.symbol.name, prefix, result, 0,
					candidate.importPath == null ? null : candidate.symbol.name, candidate.symbol.id, candidate.importPath);
			for (candidate in compiler.modules) {
				if (token != null)
					token.check();
				if (candidate.name != state.name)
					addMember(candidate.name, "module", candidate.name, prefix, result, 1);
			}
			addRecoveredImportableCompletions(state, prefix, result, token);
			sortCompletion(result);
			tagResults(result, state);
			return completionResult(result, incompleteSnapshot);
		}
		if (semanticContext != null && semanticContext.kind == SemanticCompletionContextKind.Type) {
			for (typeParameter in semanticContext.typeParameters)
				addMember(typeParameter, "typeParameter", typeParameter, prefix, result, 0);
			if (model != null)
				for (symbol in compiler.semanticWorkspace.editorVisibleSymbols(state, token))
					if (isTypeCompletionKind(symbol.kind)) {
						var signature = compiler.semanticWorkspace.editorSignature(state, symbol.id);
						addMember(symbol.name, completionDeclarationKind(symbol.kind), symbol.name, prefix, result, 0,
							signature == null ? null : symbol.name + "<");
					}
			for (candidate in compiler.semanticWorkspace.importableSymbols(state, token))
				if (isTypeCompletionKind(candidate.symbol.kind))
					addMember(candidate.symbol.name, completionDeclarationKind(candidate.symbol.kind), candidate.symbol.name, prefix, result, 1,
						candidate.importPath == null ? null : candidate.symbol.name, candidate.symbol.id, candidate.importPath);
			addRecoveredVisibleCompletions(state, ast, prefix, result, token, true);
			for (symbol in documentSymbols(path, token))
				if (symbol.kind == "class" || symbol.kind == "interface" || symbol.kind == "enum" || symbol.kind == "type" || symbol.kind == "abstract")
					addMember(symbol.name, symbol.kind, symbol.detail, prefix, result, 2);
			sortCompletion(result);
			tagResults(result, state);
			return completionResult(result, incompleteSnapshot);
		}
		if (qualifier != null) {
			if (semanticContext != null && semanticContext.receiver != null)
				addInstanceMembers(semanticContext.receiver, prefix, result, token);
			addImportedMembers(ast, qualifier, prefix, result, token);
			if (model != null)
				for (symbol in compiler.semanticWorkspace.editorVisibleSymbols(state, token)) {
					var separator = symbol.name.lastIndexOf(".");
					if (symbol.kind == DeclarationKind.EnumCase
						&& separator > 0
						&& sourceName(symbol.name.substring(0, separator)) == qualifier)
						addMember(symbol.name.substring(separator + 1), "enumCase", symbol.name, prefix, result);
				}
			for (enumDecl in ast.enums) {
				if (token != null)
					token.check();
				if (enumDecl.name == qualifier)
					for (caseDecl in enumDecl.cases) {
						if (token != null)
							token.check();
						if (prefix.length == 0 || StringTools.startsWith(caseDecl.name, prefix))
							result.push({
								label: caseDecl.name,
								kind: "enumCase",
								detail: '${enumDecl.name}.${caseDecl.name}(${[for (param in caseDecl.params) (param.optional ? "?" : "") + typeName(param.type)].join(",")})'
							});
					}
			}
			for (classDecl in ast.classes) {
				if (token != null)
					token.check();
				if (classDecl.name == qualifier) {
					for (field in classDecl.fields) {
						if (token != null)
							token.check();
						if (field.isStatic && (prefix.length == 0 || StringTools.startsWith(field.name, prefix)))
							result.push({label: field.name, kind: "field", detail: '${field.name}:${typeName(field.type)}'});
					}
					for (method in classDecl.methods) {
						if (token != null)
							token.check();
						if (method.isStatic && (prefix.length == 0 || StringTools.startsWith(method.name, prefix)))
							result.push({
								label: method.name,
								kind: "method",
								detail: '${method.name}(${[for (argument in method.arguments) typeName(argument.type)].join(",")}):${typeName(method.result)}'
							});
					}
				}
			}
			if (result.length > 0) {
				sortCompletion(result);
				tagResults(result, state);
				return completionResult(result, incompleteSnapshot);
			}
		}
		if (semanticContext != null)
			for (local in semanticContext.locals) {
				if (token != null)
					token.check();
				addMember(local.name, "variable", local.name + ":" + compilerTypeName(local.type), prefix,
					result, semanticContext.expected != null && completionTypeCompatible(local.type, semanticContext.expected) ? 0 : 2);
			}
		if (semanticContext != null && semanticContext.expected != null)
			for (symbol in compiler.semanticWorkspace.enumCases(semanticContext.expected, token)) {
				if (token != null)
					token.check();
				var label = sourceName(symbol.name),
					signature = compiler.semanticWorkspace.indexedSignature(symbol.id),
					insertText = signature != null && signature.parameters.length > 0 ? label + "(" : label;
				addMember(label, "enumCase", symbol.name, prefix, result, 1, insertText);
			}
		if (model != null)
			for (symbol in compiler.semanticWorkspace.editorVisibleSymbols(state, token)) {
				if (token != null)
					token.check();
				if (symbol.name.indexOf(".") < 0) {
					var signature = compiler.semanticWorkspace.indexedSignature(symbol.id);
					addMember(symbol.name, completionDeclarationKind(symbol.kind), symbol.name, prefix, result, 3,
						signature == null ? null : symbol.name + "(", Std.string(symbol.id));
				}
			}
		addRecoveredVisibleCompletions(state, ast, prefix, result, token);
		if (qualifier == null)
			for (candidate in compiler.semanticWorkspace.importableSymbols(state, token)) {
				if (token != null)
					token.check();
				var symbol = candidate.symbol,
					signature = compiler.semanticWorkspace.indexedSignature(symbol.id);
				addMember(symbol.name, completionDeclarationKind(symbol.kind), symbol.name, prefix, result, 4, signature == null ? null : symbol.name + "(",
					Std.string(symbol.id), candidate.importPath);
			}
		if (qualifier == null) {
			var candidates = workspaceSymbols(prefix, token),
				counts:Map<String, Int> = [];
			for (candidate in candidates) {
				if (token != null)
					token.check();
				if (candidate.container == null && isImportableCompletionKind(candidate.kind))
					counts.set(candidate.name, (counts.exists(candidate.name) ? counts.get(candidate.name) : 0) + 1);
			}
			for (candidate in candidates) {
				if (token != null)
					token.check();
				var module = ModulePath.fromFile(candidate.path);
				if (candidate.container == null
					&& isImportableCompletionKind(candidate.kind)
					&& counts.get(candidate.name) == 1
					&& module != state.name)
					addMember(candidate.name, candidate.kind, candidate.detail, prefix, result, 4, null, "workspace|" + candidate.identity, module);
			}
		}
		for (symbol in documentSymbols(path, token))
			addMember(symbol.name, symbol.kind, symbol.detail, prefix, result);
		sortCompletion(result);
		tagResults(result, state);
		return completionResult(result, incompleteSnapshot);
	}

	/** Add top-level declarations visible through current editor snapshots. */
	function addRecoveredVisibleCompletions(state:ModuleState, program:AstProgram, prefix:String, result:Array<CompletionItem>,
			token:Null<CancellationToken>, typesOnly:Bool = false):Void {
		for (candidate in compiler.modules) {
			if (token != null)
				token.check();
			if (candidate == state)
				continue;
			var candidateAst = effectiveAst(candidate);
			if (candidateAst == null || !recoveryModuleVisible(program, candidate, candidateAst))
				continue;
			var completionAst = recoveredCompletionProgram(candidate, candidateAst);
			var identityFor = function(name:String):Null<String> {
				var identity = compiler.semanticWorkspace.resolveSymbolId(candidate.name + "." + name);
				return identity == null ? null : Std.string(identity);
			};
			for (alias in completionAst.aliases) {
				if (token != null)
					token.check();
				var name = recoveredCompletionName(program, candidate, alias.name);
				addMember(name, "type", 'typedef ${alias.name}=${typeName(alias.type)}', prefix, result, 2, name, identityFor(alias.name));
			}
			for (decl in completionAst.enums) {
				if (token != null)
					token.check();
				addMember(recoveredCompletionName(program, candidate, decl.name), "enum", 'enum ${decl.name}', prefix, result, 2, null,
					identityFor(decl.name));
			}
			for (decl in completionAst.enumAbstracts) {
				if (token != null)
					token.check();
				addMember(recoveredCompletionName(program, candidate, decl.name), "abstract", 'abstract ${decl.name}', prefix, result, 2, null,
					identityFor(decl.name));
			}
			for (decl in completionAst.abstracts) {
				if (token != null)
					token.check();
				addMember(recoveredCompletionName(program, candidate, decl.name), "abstract", 'abstract ${decl.name}', prefix, result, 2, null,
					identityFor(decl.name));
			}
			for (decl in completionAst.interfaces) {
				if (token != null)
					token.check();
				addMember(recoveredCompletionName(program, candidate, decl.name), "interface", 'interface ${decl.name}', prefix, result, 2, null,
					identityFor(decl.name));
			}
			for (decl in completionAst.classes) {
				if (token != null)
					token.check();
				addMember(recoveredCompletionName(program, candidate, decl.name), "class", 'class ${decl.name}', prefix, result, 2, null,
					identityFor(decl.name));
			}
			if (typesOnly)
				continue;
			for (fn in completionAst.functions) {
				if (token != null)
					token.check();
				addMember(fn.name, "function", '${fn.name}(${[for (argument in fn.arguments) typeName(argument.type)].join(",")}):${typeName(fn.result)}', prefix, result, 2,
					fn.name + "(", identityFor(fn.name));
			}
		}
	}

	/** Add unique top-level declarations from modules that only have editor snapshots. */
	function addRecoveredImportableCompletions(state:ModuleState, prefix:String, result:Array<CompletionItem>,
			token:Null<CancellationToken>):Void {
		var candidates:Map<String, RecoveredCompletionCandidate> = [],
			counts:Map<String, Int> = [];
		for (candidate in compiler.modules) {
			if (token != null)
				token.check();
			if (candidate == state)
				continue;
			var ast = effectiveAst(candidate);
			if (ast == null)
				continue;
			var completionAst = recoveredCompletionProgram(candidate, ast),
				add = function(name:String, kind:String, detail:String, insertText:Null<String>):Void {
					if (name.length == 0)
						return;
					counts.set(name, (counts.exists(name) ? counts.get(name) : 0) + 1);
					if (!candidates.exists(name))
						candidates.set(name, {kind: kind, detail: detail, insertText: insertText, importPath: candidate.name});
				};
			for (alias in completionAst.aliases)
				add(alias.name, "type", 'typedef ${alias.name}=${typeName(alias.type)}', alias.name);
			for (decl in completionAst.enums)
				add(decl.name, "enum", 'enum ${decl.name}', null);
			for (decl in completionAst.enumAbstracts)
				add(decl.name, "abstract", 'abstract ${decl.name}', null);
			for (decl in completionAst.abstracts)
				add(decl.name, "abstract", 'abstract ${decl.name}', null);
			for (decl in completionAst.interfaces)
				add(decl.name, "interface", 'interface ${decl.name}', null);
			for (decl in completionAst.classes)
				add(decl.name, "class", 'class ${decl.name}', null);
			for (fn in completionAst.functions)
				add(fn.name, "function", '${fn.name}(${[for (argument in fn.arguments) typeName(argument.type)].join(",")}):${typeName(fn.result)}', fn.name + "(");
		}
		for (name in candidates.keys())
			if (counts.get(name) == 1) {
				if (token != null)
					token.check();
				var candidate = candidates.get(name);
				addMember(name, candidate.kind, candidate.detail, prefix, result, 1, candidate.insertText, null, candidate.importPath);
			}
	}

	function recoveredCompletionProgram(state:ModuleState, ast:AstProgram):AstProgram {
		var cached = recoveredCompletionPrograms.get(state.name);
		if (cached != null && cached.revision == state.revision)
			return cached.program;
		var program = SignatureInference.inferProgram(ast);
		recoveredCompletionPrograms.set(state.name, {revision: state.revision, program: program});
		return program;
	}

	static function recoveredCompletionName(program:AstProgram, candidate:ModuleState, name:String):String {
		for (importPath in program.imports)
			if (!StringTools.endsWith(importPath, ".*")
				&& modulePathMatches(candidate.name, importPath)
				&& importQualifier(program, importPath) != sourceName(importPath)
				&& name == sourceName(importPath))
				return importQualifier(program, importPath);
		return name;
	}

	public function resolveCompletion(path:String, identity:String, revision:Int, ?importPath:String):Null<ResolvedCompletion> {
		var state = stateFor(path);
		if (state == null || state.revision != revision)
			return null;
		if (StringTools.startsWith(identity, "workspace|")) {
			var candidate = workspaceSymbolIdentity(identity.substring("workspace|".length));
			if (candidate == null)
				return null;
			var edits:Array<TextEdit> = [],
				edit = importPath == null ? null : importEdit(state, importPath);
			if (edit != null)
				edits.push(edit);
			return {
				detail: candidate.detail,
				documentation: candidate.documentation == null
				|| candidate.documentation.length == 0 ? "Declared in " + candidate.path : candidate.documentation,
				edits: edits
			};
		}
		var resolved = compiler.semanticWorkspace.editorSymbol(state, cast identity);
		if (resolved == null)
			return null;
		var signature = compiler.semanticWorkspace.editorSignature(state, cast identity),
			edits:Array<TextEdit> = [];
		if (importPath != null) {
			var edit = importEdit(state, importPath);
			if (edit != null)
				edits.push(edit);
		}
		var documentation = documentationFor(resolved.state, resolved.symbol.declaration);
		return {
			detail: signature == null ? resolved.symbol.name + ":" + Std.string(resolved.symbol.kind) : signature.label,
			documentation: documentation.markdown.length == 0 ? "Declared in " + resolved.state.source.path : documentation.markdown,
			edits: edits
		};
	}

	public function documentHighlights(path:String, position:Int, ?token:CancellationToken):Array<DocumentHighlight> {
		if (token != null)
			token.check();
		var context = semanticQuery(path, position, null, token),
			result:Array<DocumentHighlight> = [];
		if (context == null || context.symbol == null)
			return result;
		var declaration = context.model.index.symbol(context.symbol),
			source = context.snapshot.source;
		for (span in context.model.index.locations(context.symbol)) {
			if (token != null)
				token.check();
			result.push({
				span: span,
				write: declaration != null && sameSpan(span, declaration.declaration) || assignmentFollows(source, span.end)
			});
		}
		result.sort(function(left, right) return Reflect.compare(left.span.start, right.span.start));
		return result;
	}

	public function semanticTokens(path:String, ?token:CancellationToken):Array<SemanticToken> {
		var state = stateFor(path),
			result:Array<SemanticToken> = [],
			snapshot = state == null ? null : editorSnapshot(state),
			tokens = snapshot == null ? null : snapshot.tokens,
			model = snapshot == null ? null : snapshot.semanticModel;
		if (state == null || tokens == null)
			return result;
		for (index in 0...tokens.length) {
			var lexical = tokens[index];
			if (token != null)
				token.check();
			if (lexical.kind == Eof)
				continue;
			var type:Null<String> = switch lexical.kind {
				case Identifier: var semantic = semanticTokenType(model,
						lexical.span.start); semantic == "variable" && isParameterToken(tokens, index) ? "parameter" : semantic;
				case TypeInt, TypeBool, TypeFloat, TypeString, Void: "type";
				case Integer, Float: "number";
				case StringLiteral: "string";
				case LeftParen, RightParen, LeftBrace, RightBrace, Colon, Semicolon, Comma, Dot, Assign, PlusAssign, MinusAssign, Increment, Decrement, Plus,
					Minus, Arrow, Star, Slash, Percent, Less, Greater, LessEqual, GreaterEqual, EqualEqual, NotEqual, Not, BitNot, AndAnd, OrOr, Ampersand,
					Pipe, Caret, LeftBracket, RightBracket, Question, At: "operator";
				default: "keyword";
			};
			if (type != null) {
				var indexed = model == null ? null : model.index.symbolAt(lexical.span.start), modifiers = [];
				if (indexed != null && semanticDeclaration(model, indexed.id, lexical.span)) {
					modifiers.push("declaration");
					if (documentationFor(state, indexed.declaration).deprecated)
						modifiers.push("deprecated");
					if (hasDeclarationModifier(tokens, index, Static))
						modifiers.push("static");
					if (hasDeclarationModifier(tokens, index, Final))
						modifiers.push("readonly");
				}
				addSemanticSpan(snapshot.source, lexical.span.start, lexical.span.end, type, modifiers, result);
			}
		}
		addCommentTokens(snapshot.source, result);
		result.sort(function(left, right) return Reflect.compare(left.span.start, right.span.start));
		return result;
	}

	public function hover(path:String, position:Int, ?token:CancellationToken):Null<String> {
		if (token != null)
			token.check();
		var state = stateFor(path),
			snapshot = state == null ? null : editorSnapshot(state),
			ast = snapshot == null ? null : snapshot.ast;
		if (state == null || ast == null)
			return null;
		var model = snapshot.semanticModel,
			indexedId = model == null ? null : model.index.symbolIdAt(position, token),
			indexedSignature = indexedId == null ? null : compiler.semanticWorkspace.editorSignature(state, indexedId);
		if (indexedSignature != null)
			return indexedSignature.label;
		if (indexedId != null && model != null) {
			var indexed = model.index.symbol(indexedId),
				indexedType = model.index.typeAt(position, token);
			if (indexed != null && indexedType != null)
				return indexed.name + ":" + compilerTypeName(indexedType);
		}
		var name = identifierPrefix(snapshot.source, position);
		if (name.length == 0)
			return null;
		var qualifier = memberQualifier(snapshot.source, position);
		if (qualifier != null) {
			for (enumDecl in ast.enums) {
				if (token != null)
					token.check();
				if (enumDecl.name == qualifier)
					for (caseDecl in enumDecl.cases) {
						if (token != null)
							token.check();
						if (caseDecl.name == name)
							return
								'${enumDecl.name}.${caseDecl.name}(${[for (param in caseDecl.params) (param.optional ? "?" : "") + typeName(param.type)].join(",")})';
					}
			}
			for (classDecl in ast.classes) {
				if (token != null)
					token.check();
				if (classDecl.name == qualifier)
					for (field in classDecl.fields) {
						if (token != null)
							token.check();
						if (field.name == name && field.isStatic)
							return '${field.name}:${typeName(field.type)}';
					}
			}
			var model = snapshot.semanticModel,
				context = model == null ? null : model.index.completionContext(position, qualifier, token),
				members:Array<CompletionItem> = [];
			if (context != null && context.receiver != null) {
				addInstanceMembers(context.receiver, name, members, token);
				if (members.length > 0)
					return members[0].detail;
			}
		}
		for (symbol in documentSymbols(path, token))
			if (symbol.name == name)
				return symbol.detail;
		return null;
	}

	public function hoverDocumentation(path:String, position:Int, ?token:CancellationToken):Null<SymbolDocumentation> {
		if (token != null)
			token.check();
		var context = semanticQuery(path, position, null, token);
		if (context == null || context.symbol == null)
			return null;
		var resolved = compiler.semanticWorkspace.editorSymbol(context.state, context.symbol);
		return resolved == null ? null : documentationFor(resolved.state, resolved.symbol.declaration);
	}

	public function signatureHelp(path:String, position:Int, ?token:CancellationToken):Null<SignatureHelp> {
		if (token != null)
			token.check();
		var state = stateFor(path),
			snapshot = state == null ? null : editorSnapshot(state),
			tokens = state == null ? null : effectiveTokens(state),
			model = state == null ? null : effectiveSemanticModel(state);
		if (state == null || tokens == null || model == null)
			return null;
		var open = callOpenToken(tokens, position, token);
		if (open < 1)
			return null;
		var callee = open - 1;
		while (callee >= 0 && tokens[callee].kind != Identifier) {
			if (token != null)
				token.check();
			callee--;
		}
		if (callee < 0)
			return null;
		var id = model.index.symbolIdAt(tokens[callee].span.start + 1),
			signature = id == null ? null : compiler.semanticWorkspace.editorSignature(state, id),
			qualifier = memberQualifier(snapshot.source, tokens[callee].span.end),
			calleeName = tokens[callee].text,
			recoveredName = qualifier == null ? calleeName : qualifier + "." + calleeName,
			context = qualifier == null ? null : model.index.completionContext(position, qualifier, token);
		if (snapshot.recovered)
			signature = model.index.recoveredSignature(recoveredName, context == null ? null : context.receiver);
		if (signature == null && qualifier != null) {
			var owner = context == null ? null : typeDeclaration(context.receiver);
			if (owner != null)
				signature = model.index.recoveredSignature(owner + "." + calleeName, context.receiver);
		}
		if (signature == null)
			return null;
		var active = activeCallParameter(tokens, open, position, token);
		if (signature.parameters.length > 0 && active >= signature.parameters.length)
			active = signature.parameters.length - 1;
		var result:SignatureHelp = {
			label: signature.label,
			parameters: signature.parameters,
			activeParameter: active
		};
		var resolved = id == null ? null : compiler.semanticWorkspace.editorSymbol(state, id),
			documentation = resolved == null ? null : documentationFor(resolved.state, resolved.symbol.declaration);
		if (documentation != null) {
			Reflect.setField(result, "documentation", documentation.markdown);
			Reflect.setField(result, "parameterDocumentation", [
				for (parameter in signature.parameters) {
					var separator = parameter.indexOf(":"),
						name = separator < 0 ? parameter : parameter.substring(0, separator);
					documentation.parameters.get(name);
				}
			]);
		}
		tagResults([result], state);
		return result;
	}

	static function callOpenToken(tokens:Array<compiler.syntax.Token>, position:Int, ?cancellation:CancellationToken):Int {
		var depth = 0;
		var index = tokens.length - 1;
		while (index >= 0 && tokens[index].span.start >= position) {
			if (cancellation != null)
				cancellation.check();
			index--;
		}
		while (index >= 0) {
			if (cancellation != null)
				cancellation.check();
			switch tokens[index].kind {
				case RightParen:
					depth++;
				case LeftParen:
					if (depth == 0)
						return index;
					depth--;
				default:
			}
			index--;
		}
		return -1;
	}

	static function activeCallParameter(tokens:Array<compiler.syntax.Token>, open:Int, position:Int, ?cancellation:CancellationToken):Int {
		var depth = 0, active = 0;
		for (index in open + 1...tokens.length) {
			if (cancellation != null)
				cancellation.check();
			var lexical = tokens[index];
			if (lexical.span.start >= position)
				break;
			switch lexical.kind {
				case LeftParen, LeftBracket, LeftBrace:
					depth++;
				case RightParen, RightBracket, RightBrace:
					if (depth > 0)
						depth--;
				case Comma:
					if (depth == 0)
						active++;
				default:
			}
		}
		return active;
	}

	public function definition(path:String, position:Int, ?token:CancellationToken):Null<SymbolLocation> {
		return indexedDefinition(path, position, token);
	}

	public function typeDefinition(path:String, position:Int, ?token:CancellationToken):Null<SymbolLocation> {
		if (token != null)
			token.check();
		var context = semanticQuery(path, position, null, token);
		if (context == null || context.confidence == EditorSnapshotConfidence.RecoveredPartial)
			return null;
		var target:Null<SemanticSymbolId> = null,
			symbol = context.symbol == null ? null : compiler.semanticWorkspace.editorSymbol(context.state, context.symbol);
		if (symbol != null && isTypeDeclaration(symbol.symbol.kind))
			target = symbol.symbol.id;
		else {
			var declaration = typeDeclaration(context.model.index.typeAt(position, token));
			if (declaration != null)
				target = compiler.semanticWorkspace.resolveTypeSymbolId(declaration);
		}
		if (target == null)
			return null;
		var resolved = target == null ? null : compiler.semanticWorkspace.editorSymbol(context.state, target);
		return resolved == null ? null : {
			path: resolved.symbol.declaration.file.path,
			span: resolved.symbol.declaration,
			revision: snapshotRevision(resolved.state),
			stale: snapshotRevision(resolved.state) != resolved.state.revision
		};
	}

	public function implementations(path:String, position:Int, ?token:CancellationToken):Array<SymbolLocation> {
		var context = semanticQuery(path, position, null, token);
		if (!navigableSymbol(context))
			return [];
		return [
			for (implementation in compiler.semanticWorkspace.implementations(context.symbol, token))
				{
					path: implementation.span.file.path,
					span: implementation.span,
					revision: snapshotRevision(implementation.state),
					stale: snapshotRevision(implementation.state) != implementation.state.revision
				}
		];
	}

	static function typeDeclaration(type:Null<CompilerType>):Null<String>
		return switch type {
			case TNullable(element): typeDeclaration(element);
			case TAbstract(declaration, _, _), TInstance(_, declaration, _): cast declaration;
			default: null;
		};

	static function isTypeDeclaration(kind:DeclarationKind):Bool
		return kind == DeclarationKind.Alias || kind == DeclarationKind.Enum || kind == DeclarationKind.Abstract || kind == DeclarationKind.Interface
			|| kind == DeclarationKind.Class;

	function indexedDefinition(path:String, position:Int, ?token:CancellationToken):Null<SymbolLocation> {
		if (token != null)
			token.check();
		var context = semanticQuery(path, position, null, token);
		if (!navigableSymbol(context))
			return null;
		var resolved = context.symbol == null ? null : compiler.semanticWorkspace.editorSymbol(context.state, context.symbol);
		return resolved == null ? null : {
			path: resolved.symbol.declaration.file.path,
			span: resolved.symbol.declaration,
			revision: snapshotRevision(resolved.state),
			stale: snapshotRevision(resolved.state) != resolved.state.revision
		};
	}

	public function references(path:String, position:Int, ?token:CancellationToken):Array<SymbolLocation> {
		var indexed = indexedReferences(path, position, token);
		return indexed == null ? [] : indexed;
	}

	function indexedReferences(path:String, position:Int, ?token:CancellationToken):Null<Array<SymbolLocation>> {
		var context = semanticQuery(path, position, null, token);
		if (!stableSymbol(context))
			return null;
		var id = context.symbol;
		if (id == null)
			return null;
		var result:Array<SymbolLocation> = [
			for (location in compiler.semanticWorkspace.editorLocations(context.state, id, token))
				{
					path: location.span.file.path,
					span: location.span,
					revision: snapshotRevision(location.state),
					stale: snapshotRevision(location.state) != location.state.revision
				}
		];
		result.sort(function(left, right) {
			var path = Reflect.compare(left.path, right.path);
			return path == 0 ? Reflect.compare(left.span.start, right.span.start) : path;
		});
		return result.length > MAX_REFERENCE_RESULTS ? result.slice(0, MAX_REFERENCE_RESULTS) : result;
	}

	public function rename(path:String, position:Int, replacement:String, ?token:CancellationToken):Array<TextEdit> {
		if (token != null)
			token.check();
		var context = semanticQuery(path, position, null, token),
			indexedId = context == null ? null : context.symbol,
			name = symbolAt(path, position),
			result:Array<TextEdit> = [];
		if (context == null
			|| context.confidence != EditorSnapshotConfidence.Exact
			|| name == null
			|| !isIdentifier(replacement)
			|| replacement == name)
			return result;
		var targetReferences = references(path, position, token);
		for (reference in targetReferences) {
			if (token != null)
				token.check();
			var referenceState = stateFor(reference.path);
			if (reference.stale || referenceState == null || referenceState.ast == null)
				return result;
		}
		if (indexedRenameCollides(indexedId, replacement, targetReferences, token))
			return result;
		for (reference in targetReferences)
			result.push({
				path: reference.path,
				span: reference.span,
				replacement: replacement,
				revision: reference.revision,
				stale: reference.stale
			});
		return result;
	}

	function indexedRenameCollides(target:SemanticSymbolId, replacement:String, affected:Array<SymbolLocation>, ?token:CancellationToken):Bool {
		var affectedPaths:Map<String, Bool> = [];
		for (location in affected) {
			if (token != null)
				token.check();
			affectedPaths.set(location.path, true);
		}
		for (state in compiler.modules) {
			if (token != null)
				token.check();
			if (!affectedPaths.exists(state.source.path))
				continue;
			var tokens = effectiveTokens(state),
				model = effectiveSemanticModel(state);
			if (tokens != null && model != null)
				for (lexical in tokens) {
					if (token != null)
						token.check();
					if (lexical.kind == Identifier && lexical.text == replacement) {
						var existing = model.index.symbolIdAt(lexical.span.start + 1);
						if (existing != null && Std.string(existing) != Std.string(target) && semanticNamesCollide(target, existing))
							return true;
					}
				}
		}
		return false;
	}

	function semanticNamesCollide(left:SemanticSymbolId, right:SemanticSymbolId):Bool {
		var leftSymbol = compiler.semanticWorkspace.indexedSymbol(left),
			rightSymbol = compiler.semanticWorkspace.indexedSymbol(right);
		if (leftSymbol == null || rightSymbol == null)
			return false;
		var leftLocal = localCollisionScope(left),
			rightLocal = localCollisionScope(right);
		if (leftLocal != null || rightLocal != null)
			return leftLocal != null && leftLocal == rightLocal;
		if (leftSymbol.symbol.kind == DeclarationKind.Member && rightSymbol.symbol.kind == DeclarationKind.Member)
			return declarationOwner(leftSymbol.symbol.name) == declarationOwner(rightSymbol.symbol.name);
		return leftSymbol.state.name == rightSymbol.state.name;
	}

	static function localCollisionScope(id:SemanticSymbolId):Null<String> {
		var value = Std.string(id), marker = value.indexOf(":local:");
		if (marker < 0)
			return null;
		var identity = value.indexOf(":$" + "l", marker + 7);
		return identity < 0 ? value : value.substring(0, identity);
	}

	static function declarationOwner(name:String):String {
		var separator = name.lastIndexOf(".");
		return separator < 0 ? name : name.substring(0, separator);
	}

	function symbolAt(path:String, position:Int):Null<String> {
		var state = stateFor(path);
		var tokens = state == null ? null : effectiveTokens(state);
		if (state == null || tokens == null)
			return null;
		for (token in tokens)
			if (token.kind == Identifier && position >= token.span.start && position <= token.span.end)
				return token.text;
		return null;
	}

	static function isIdentifier(value:String):Bool {
		if (value.length == 0 || !isIdentifierStart(value.charCodeAt(0)))
			return false;
		for (i in 1...value.length)
			if (!isIdentifierPart(value.charCodeAt(i)))
				return false;
		return true;
	}

	function semanticQuery(path:String, position:Int, ?qualifier:String, ?token:CancellationToken):Null<SemanticQueryContext> {
		if (token != null)
			token.check();
		var state = stateFor(path),
			snapshot = state == null ? null : editorSnapshot(state),
			model = snapshot == null ? null : snapshot.semanticModel;
		var symbol = model == null ? null : model.index.symbolIdAt(position, token),
			confidence = snapshot == null ? null : snapshot.confidence == EditorSnapshotConfidence.RecoveredPartial
				&& symbol != null ? EditorSnapshotConfidence.RecoveredStable : snapshot.confidence;
		return state == null || snapshot == null || model == null ? null : {
			state: state,
			snapshot: snapshot,
			model: model,
			symbol: symbol,
			completion: model.index.completionContext(position, qualifier, token),
			stale: snapshot.stale,
			confidence: confidence
		};
	}

	static function stableSymbol(context:Null<SemanticQueryContext>):Bool
		return context != null
			&& context.symbol != null
			&& (context.confidence == EditorSnapshotConfidence.Exact || context.confidence == EditorSnapshotConfidence.RecoveredStable);

	static function navigableSymbol(context:Null<SemanticQueryContext>):Bool
		return context != null && context.symbol != null && context.confidence != EditorSnapshotConfidence.RecoveredPartial;

	static function sourceName(name:String):String {
		var separator = name.lastIndexOf(".");
		return separator < 0 ? name : name.substring(separator + 1);
	}

	static function completionDeclarationKind(kind:DeclarationKind):String
		return switch kind {
			case DeclarationKind.Alias: "type";
			case DeclarationKind.EnumCase: "enumCase";
			default: Std.string(kind);
		};

	static function isImportableCompletionKind(kind:String):Bool
		return kind == "type" || kind == "class" || kind == "interface" || kind == "enum" || kind == "function";

	static function isTypeCompletionKind(kind:DeclarationKind):Bool
		return switch kind {
			case DeclarationKind.Alias, DeclarationKind.Abstract, DeclarationKind.Class, DeclarationKind.Enum, DeclarationKind.Interface,
				DeclarationKind.TypeParameter: true;
			default: false;
		};

	function addInstanceMembers(type:CompilerType, prefix:String, result:Array<CompletionItem>, token:Null<CancellationToken>,
		?visiting:Map<String, Bool>):Void {
		if (token != null)
			token.check();
		var seen:Map<String, Bool> = visiting == null ? [] : visiting,
			visitKey = compilerTypeName(type);
		if (seen.exists(visitKey))
			return;
		seen.set(visitKey, true);
		switch type {
			case TNullable(element):
				addInstanceMembers(element, prefix, result, token, seen);
			case TInstance(Class, name, arguments):
				for (state in compiler.modules) {
					if (token != null)
						token.check();
					var ast = effectiveAst(state);
					if (ast != null)
						for (classDecl in ast.classes)
							if (classDecl.name == name) {
								var substitutions:Map<String, String> = [];
								for (index in 0...classDecl.typeParameters.length)
									if (index < arguments.length)
										substitutions.set(classDecl.typeParameters[index], compilerTypeName(arguments[index]));
								for (field in classDecl.fields) {
									if (token != null)
										token.check();
									if (!field.isStatic)
										addMember(field.name, "field", '${field.name}:${typeNameSubstituted(field.type, substitutions)}', prefix, result);
								}
								for (method in classDecl.methods) {
									if (token != null)
										token.check();
									if (!method.isStatic)
										addMember(method.name, "method",
											'${method.name}(${[for (argument in method.arguments) typeNameSubstituted(argument.type, substitutions)].join(",")}):${typeNameSubstituted(method.result, substitutions)}',
											prefix, result);
								}
								if (classDecl.base != null)
									addInstanceMembers(compilerTypeFromAst(classDecl.base, substitutions), prefix, result, token, seen);
								for (interfaceType in classDecl.interfaces)
									addInstanceMembers(compilerTypeFromAst(interfaceType, substitutions), prefix, result, token, seen);
							}
				}
			case TInstance(Interface, name, arguments):
				for (state in compiler.modules) {
					if (token != null)
						token.check();
					var ast = effectiveAst(state);
					if (ast != null)
						for (interfaceDecl in ast.interfaces)
							if (interfaceDecl.name == name) {
								var substitutions:Map<String, String> = [];
								for (index in 0...interfaceDecl.typeParameters.length)
									if (index < arguments.length)
										substitutions.set(interfaceDecl.typeParameters[index], compilerTypeName(arguments[index]));
								for (method in interfaceDecl.methods) {
									if (token != null)
										token.check();
										addMember(method.name, "method",
											'${method.name}(${[for (argument in method.arguments) typeNameSubstituted(argument.type, substitutions)].join(",")}):${typeNameSubstituted(method.result, substitutions)}',
											prefix, result);
								}
								for (baseType in interfaceDecl.bases)
									addInstanceMembers(compilerTypeFromAst(baseType, substitutions), prefix, result, token, seen);
							}
				}
			case TArray(_):
				addMember("length", "field", "length:Int", prefix, result);
				addMember("copy", "method", "copy():Array", prefix, result);
				addMember("concat", "method", "concat(other):Array", prefix, result);
				addMember("slice", "method", "slice(start,end):Array", prefix, result);
				addMember("indexOf", "method", "indexOf(value):Int", prefix, result);
				addMember("push", "method", "push(value):Int", prefix, result);
				addMember("pop", "method", "pop():Element", prefix, result);
				addMember("shift", "method", "shift():Element", prefix, result);
			case TMap(_, _):
				addMember("set", "method", "set(key,value):Void", prefix, result);
				addMember("exists", "method", "exists(key):Bool", prefix, result);
				addMember("keys", "method", "keys():Array", prefix, result);
				addMember("values", "method", "values():Array", prefix, result);
				addMember("remove", "method", "remove(key):Bool", prefix, result);
				addMember("clear", "method", "clear():Void", prefix, result);
				addMember("size", "method", "size():Int", prefix, result);
			case TString:
				addMember("length", "field", "length:Int", prefix, result);
				addMember("indexOf", "method", "indexOf(needle):Int", prefix, result);
				addMember("substring", "method", "substring(start,end):String", prefix, result);
			default:
		}
	}

	function addImportedMembers(program:compiler.syntax.Ast.AstProgram, qualifier:String, prefix:String, result:Array<CompletionItem>,
			token:Null<CancellationToken>):Void {
		for (importPath in program.imports) {
			if (token != null)
				token.check();
			var wildcard = importPath.length > 2 && StringTools.endsWith(importPath, ".*"),
				matches = importQualifier(program, importPath) == qualifier || wildcard;
			if (!matches)
				continue;
			var importedPath = wildcard ? importPath.substr(0, importPath.length - 2) + "." + qualifier : importPath,
				imported = importedModule(importedPath),
				rawAst = imported == null ? null : effectiveAst(imported);
			if (imported == null || rawAst == null)
				continue;
			var importedAst = recoveredCompletionProgram(imported, rawAst);
			var importedPrefix = importedPath + ".";
			for (fn in importedAst.functions) {
				if (token != null)
					token.check();
				var id = compiler.semanticWorkspace.resolveSymbolId(importedPrefix + fn.name);
				addMember(fn.name, "function", '${fn.name}(${[for (argument in fn.arguments) typeName(argument.type)].join(",")}):${typeName(fn.result)}',
					prefix, result, 1, fn.name + "(", id == null ? null : Std.string(id), importPath);
			}
			var importedName = sourceName(importedPath);
			for (classDecl in importedAst.classes) {
				if (token != null)
					token.check();
				if (classDecl.name == importedName) {
					for (field in classDecl.fields) {
						if (token != null)
							token.check();
						if (field.isStatic)
							addMember(field.name, "field", '${field.name}:${typeName(field.type)}', prefix, result, 1);
					}
					for (method in classDecl.methods) {
						if (token != null)
							token.check();
						if (method.isStatic)
							addMember(method.name, "method",
								'${method.name}(${[for (argument in method.arguments) typeName(argument.type)].join(",")}):${typeName(method.result)}',
								prefix, result, 1, method.name + "(");
					}
				}
			}
			for (enumDecl in importedAst.enums) {
				if (token != null)
					token.check();
				if (enumDecl.name == importedName)
					for (caseDecl in enumDecl.cases) {
						if (token != null)
							token.check();
						addMember(caseDecl.name, "enumCase",
							'${enumDecl.name}.${caseDecl.name}(${[for (param in caseDecl.params) (param.optional ? "?" : "") + typeName(param.type)].join(",")})',
							prefix, result, 1, caseDecl.params.length == 0 ? null : caseDecl.name + "(");
					}
			}
		}
	}

	static function importQualifier(program:compiler.syntax.Ast.AstProgram, importPath:String):String {
		for (alias => path in program.importAliases)
			if (path == importPath)
				return alias;
		return sourceName(importPath);
	}

	static function addMember(label:String, kind:String, detail:String, prefix:String, result:Array<CompletionItem>, ?rank:Int = 3, ?insertText:String,
			?identity:String, ?importPath:String):Void {
		if ((prefix.length == 0 || StringTools.startsWith(label, prefix)) && [for (item in result) item.label].indexOf(label) < 0)
			result.push({
				label: label,
				kind: kind,
				detail: detail,
				sortText: Std.string(rank) + "_" + label,
				insertText: insertText,
				identity: identity,
				importPath: importPath
			});
	}

	function importEdit(state:ModuleState, importPath:String):Null<TextEdit> {
		var ast = effectiveAst(state), tokens = effectiveTokens(state);
		if (ast == null || tokens == null || ast.imports.indexOf(importPath) >= 0)
			return null;
		var separator = importPath.lastIndexOf("."),
			targetPackage = separator < 0 ? "" : importPath.substring(0, separator),
			currentPackage = ast.packageName == null ? "" : Std.string(ast.packageName);
		if (targetPackage == currentPackage)
			return null;
		var insertion = 0;
		for (index in 0...tokens.length)
			if (tokens[index].kind == Semicolon
				&& index > 0
				&& (tokens[index - 1].kind == Identifier || tokens[index - 1].kind == Package)) {
				var cursor = index - 1;
				while (cursor >= 0 && (tokens[cursor].kind == Identifier || tokens[cursor].kind == Dot))
					cursor--;
				if (cursor >= 0 && (tokens[cursor].kind == Import || tokens[cursor].kind == Package))
					insertion = tokens[index].span.end;
			}
		var replacement = insertion == 0 ? 'import $importPath;\n' : '\nimport $importPath;';
		return {
			path: state.source.path,
			span: state.source.span(insertion, insertion),
			replacement: replacement,
			revision: state.revision,
			stale: false
		};
	}

	static function sortCompletion(result:Array<CompletionItem>):Void
		result.sort(function(left, right) return Reflect.compare(left.sortText, right.sortText));

	static function completionResult(result:Array<CompletionItem>, incompleteSnapshot:Bool = false):CompletionResult {
		var incomplete = incompleteSnapshot || result.length > MAX_COMPLETION_ITEMS;
		return {items: incomplete ? result.slice(0, MAX_COMPLETION_ITEMS) : result, isIncomplete: incomplete};
	}

	static function sameSpan(left:SourceSpan, right:SourceSpan):Bool
		return left.file.path == right.file.path && left.start == right.start && left.end == right.end;

	static function assignmentFollows(source:SourceFile, position:Int):Bool {
		while (position < source.bytes.length) {
			var code = source.bytes.get(position);
			if (code != 32 && code != 9 && code != 10 && code != 13)
				break;
			position++;
		}
		if (position >= source.bytes.length)
			return false;
		var current = source.bytes.get(position),
			next = position + 1 < source.bytes.length ? source.bytes.get(position + 1) : -1;
		if (current == "=".code)
			return next != "=".code && next != ">".code;
		return (current == "+".code || current == "-".code || current == "*".code || current == "/".code || current == "%".code || current == "&".code
			|| current == "|".code || current == "^".code)
			&& next == "=".code;
	}

	static function semanticTokenType(model:Null<SemanticModel>, position:Int):String {
		var symbol = model == null ? null : model.index.symbolAt(position);
		if (symbol == null)
			return "variable";
		return switch symbol.kind {
			case DeclarationKind.Alias, DeclarationKind.Abstract: "type";
			case DeclarationKind.Class: "class";
			case DeclarationKind.Interface: "interface";
			case DeclarationKind.Enum: "enum";
			case DeclarationKind.EnumCase: "enumMember";
			case DeclarationKind.TypeParameter: "typeParameter";
			case DeclarationKind.Function: "function";
			case DeclarationKind.Member:
				model.index.signature(symbol.id) != null ? "method" : Std.string(symbol.id).indexOf(":local:") >= 0 ? "variable" : "property";
		};
	}

	static function isParameterToken(tokens:Array<compiler.syntax.Token>, index:Int):Bool {
		if (index + 1 >= tokens.length || tokens[index + 1].kind != Colon)
			return false;
		var depth = 0, cursor = index - 1;
		while (cursor >= 0) {
			switch tokens[cursor].kind {
				case RightParen:
					depth++;
				case LeftParen:
					if (depth == 0)
						return cursor > 0 && (tokens[cursor - 1].kind == Identifier || tokens[cursor - 1].kind == New);
					depth--;
				case LeftBrace, RightBrace, Semicolon:
					return false;
				default:
			}
			cursor--;
		}
		return false;
	}

	static function hasDeclarationModifier(tokens:Array<compiler.syntax.Token>, index:Int, modifier:TokenKind):Bool {
		var cursor = index - 1;
		while (cursor >= 0) {
			var kind = tokens[cursor].kind;
			if (kind == modifier)
				return true;
			if (kind == LeftBrace || kind == RightBrace || kind == Semicolon)
				return false;
			cursor--;
		}
		return false;
	}

	static function semanticDeclaration(model:SemanticModel, id:SemanticSymbolId, span:SourceSpan):Bool {
		var locations = model.index.locations(id);
		return locations.length > 0 && sameSpan(locations[0], span);
	}

	static function addCommentTokens(file:compiler.Source.SourceFile, result:Array<SemanticToken>):Void {
		var source = file.text, position = 0;
		while (position + 1 < source.length) {
			var quote = source.charAt(position);
			if (quote == "\"" || quote == "'") {
				position++;
				while (position < source.length) {
					if (source.charAt(position) == "\\")
						position += 2;
					else if (source.charAt(position++) == quote)
						break;
				}
				continue;
			}
			if (source.charAt(position) != "/") {
				position++;
				continue;
			}
			var next = source.charAt(position + 1), start = position;
			if (next == "/") {
				position += 2;
				while (position < source.length && source.charCodeAt(position) != 10)
					position++;
				addSemanticSpan(file, file.byteOffsetForStringOffset(start), file.byteOffsetForStringOffset(position), "comment", [], result);
			} else if (next == "*") {
				position += 2;
				while (position + 1 < source.length && !(source.charAt(position) == "*" && source.charAt(position + 1) == "/"))
					position++;
				position = Std.int(Math.min(source.length, position + 2));
				addSemanticSpan(file, file.byteOffsetForStringOffset(start), file.byteOffsetForStringOffset(position), "comment", [], result);
			} else
				position++;
		}
	}

	static function addSemanticSpan(file:compiler.Source.SourceFile, start:Int, end:Int, type:String, modifiers:Array<String>,
			result:Array<SemanticToken>):Void {
		var partStart = start, position = start;
		while (position < end) {
			if (file.bytes.get(position) == "\n".code) {
				if (position > partStart)
					result.push({span: file.span(partStart, position), type: type, modifiers: modifiers.copy()});
				partStart = position + 1;
			}
			position++;
		}
		if (end > partStart)
			result.push({span: file.span(partStart, end), type: type, modifiers: modifiers.copy()});
	}

	static function completionTypeCompatible(actual:CompilerType, expected:CompilerType):Bool {
		if (actual == TUnknown || actual == TError || expected == TUnknown || expected == TError)
			return true;
		if (TypeRelations.equals(actual, expected))
			return true;
		return switch expected {
			case TDynamic: true;
			case TNullable(element): completionTypeCompatible(actual, element);
			default: false;
		};
	}

	function addParameterHints(path:String, tokens:Array<compiler.syntax.Token>, open:Int, start:Int, end:Int, result:Array<InlayHint>,
			token:Null<CancellationToken>):Void {
		if (token != null)
			token.check();
		var signature = signatureHelp(path, tokens[open].span.end, token);
		if (signature == null || signature.parameters.length == 0)
			return;
		var depth = 1, argument = 0, cursor = open + 1, argumentStart = cursor;
		while (cursor < tokens.length && depth > 0) {
			if (token != null)
				token.check();
			var kind = tokens[cursor].kind;
			switch kind {
				case LeftParen, LeftBracket, LeftBrace:
					depth++;
				case RightParen, RightBracket, RightBrace:
					depth--;
					if (depth == 0) {
						addParameterHint(tokens, argumentStart, cursor, argument, signature.parameters, start, end, result);
						break;
					}
				case Comma:
					if (depth == 1) {
						addParameterHint(tokens, argumentStart, cursor, argument++, signature.parameters, start, end, result);
						argumentStart = cursor + 1;
					}
				default:
			}
			cursor++;
		}
	}

	static function addParameterHint(tokens:Array<compiler.syntax.Token>, startIndex:Int, endIndex:Int, argument:Int, parameters:Array<String>,
			rangeStart:Int, rangeEnd:Int, result:Array<InlayHint>):Void {
		if (argument >= parameters.length || startIndex >= endIndex)
			return;
		var first = tokens[startIndex],
			parameter = parameters[argument],
			separator = parameter.indexOf(":"),
			name = separator < 0 ? parameter : parameter.substring(0, separator);
		if (first.span.start < rangeStart || first.span.start > rangeEnd || first.kind == Identifier && first.text == name)
			return;
		result.push({
			position: first.span.start,
			label: name + ":",
			kind: "parameter",
			paddingLeft: false,
			paddingRight: true
		});
	}

	function indexedWorkspaceSymbols(state:ModuleState, ?token:CancellationToken):Array<WorkspaceSymbol> {
		if (token != null)
			token.check();
		var cached = workspaceIndex.get(state.name);
		if (cached != null && cached.revision == state.revision)
			return cached.symbols;
		var ast = effectiveAst(state);
		if (ast == null)
			try {
				var conditional = ConditionalCompilation.process(state.source, editorDefines);
				ast = new Parser(new Lexer(state.source, conditional.text).tokenize()).parseProgram();
			} catch (_:CompileError) {}
		var result:Array<WorkspaceSymbol> = [];
		if (ast != null) {
			for (fn in ast.functions) {
				if (token != null)
					token.check();
				addWorkspaceSymbol(result, state, fn.name, "function", null, '${fn.name}():${typeName(fn.result)}', fn.span);
			}
			for (alias in ast.aliases) {
				if (token != null)
					token.check();
				addWorkspaceSymbol(result, state, alias.name, "type", null, 'typedef ${alias.name}=${typeName(alias.type)}', alias.span);
			}
			for (decl in ast.interfaces) {
				if (token != null)
					token.check();
				addWorkspaceSymbol(result, state, decl.name, "interface", null, 'interface ${decl.name}', decl.span);
				for (method in decl.methods) {
					if (token != null)
						token.check();
					addWorkspaceSymbol(result, state, method.name, "method", decl.name, '${method.name}():${typeName(method.result)}', method.span);
				}
			}
			for (decl in ast.enums) {
				if (token != null)
					token.check();
				addWorkspaceSymbol(result, state, decl.name, "enum", null, 'enum ${decl.name}', decl.span);
				for (item in decl.cases) {
					if (token != null)
						token.check();
					addWorkspaceSymbol(result, state, item.name, "enumCase", decl.name, decl.name + "." + item.name, item.span);
				}
			}
			for (decl in ast.classes) {
				if (token != null)
					token.check();
				addWorkspaceSymbol(result, state, decl.name, "class", null, 'class ${decl.name}', decl.span);
				for (field in decl.fields) {
					if (token != null)
						token.check();
					addWorkspaceSymbol(result, state, field.name, "field", decl.name, '${field.name}:${typeName(field.type)}', field.span);
				}
				for (method in decl.methods) {
					if (token != null)
						token.check();
					addWorkspaceSymbol(result, state, method.name, "method", decl.name, '${method.name}():${typeName(method.result)}', method.span);
				}
			}
		}
		workspaceIndex.set(state.name, {revision: state.revision, symbols: result});
		return result;
	}

	function documentationFor(state:ModuleState, span:SourceSpan):SymbolDocumentation {
		var cached = documentationIndex.get(state.name);
		if (span.file == state.source) {
			if (cached == null || cached.revision != state.revision) {
				cached = {revision: state.revision, comments: DocumentationTools.scan(state.source)};
				documentationIndex.set(state.name, cached);
			}
			return DocumentationTools.forSpan(state.source, cached.comments, span);
		}
		return DocumentationTools.forSpan(span.file, DocumentationTools.scan(span.file), span);
	}

	function indexedStructure(state:ModuleState, ?token:CancellationToken):StructuralIndexEntry {
		if (token != null)
			token.check();
		var cached = structuralIndex.get(state.name);
		if (cached != null && cached.revision == state.revision)
			return cached;
		var folds:Array<FoldingRegion> = [],
			containers:Array<SourceSpan> = [],
			snapshot = editorSnapshot(state),
			tokens = snapshot == null ? null : snapshot.tokens,
			source = snapshot == null ? state.source : snapshot.source;
		if (tokens != null) {
			var braces:Array<compiler.syntax.Token> = [],
				firstImport:Null<Int> = null,
				lastImport:Null<Int> = null,
				inImport = false;
			for (lexicalToken in tokens) {
				if (token != null)
					token.check();
				switch lexicalToken.kind {
					case LeftBrace:
						braces.push(lexicalToken);
					case RightBrace:
						if (braces.length > 0) {
							var open = braces.pop(),
								span = source.span(open.span.start, lexicalToken.span.end);
							folds.push({span: span, kind: "region"});
							containers.push(span);
						}
					case Import:
						inImport = true;
						if (firstImport == null)
							firstImport = lexicalToken.span.start;
					case Semicolon:
						if (inImport) {
							lastImport = lexicalToken.span.end;
							inImport = false;
						}
					default:
				}
			}
			for (open in braces) {
				var span = source.span(open.span.start, source.bytes.length);
				folds.push({span: span, kind: "region"});
				containers.push(span);
			}
			if (firstImport != null && lastImport != null)
				folds.push({span: source.span(firstImport, lastImport), kind: "imports"});
		}
		for (span in commentSpans(source.text, source, token)) {
			folds.push({span: span, kind: "comment"});
			containers.push(span);
		}
		addConditionalFolds(source, folds, containers, token);
		for (symbol in indexedWorkspaceSymbols(state, token)) {
			if (token != null)
				token.check();
			containers.push(symbol.span);
		}
		containers.push(source.span(0, source.bytes.length));
		folds.sort(function(left, right) return Reflect.compare(left.span.start, right.span.start));
		structuralIndex.set(state.name, cached = {revision: state.revision, folds: folds, containers: containers});
		return cached;
	}

	static function commentSpans(text:String, file:compiler.Source.SourceFile, ?token:CancellationToken):Array<SourceSpan> {
		var result:Array<SourceSpan> = [], position = 0;
		while (position + 1 < text.length) {
			if (token != null)
				token.check();
			var quote = text.charAt(position);
			if (quote == "\"" || quote == "'") {
				position++;
				while (position < text.length)
					if (text.charAt(position) == "\\")
						position += 2;
					else if (text.charAt(position++) == quote)
						break;
				continue;
			}
			var marker = text.substr(position, 2), start = position;
			if (marker == "//") {
				var newline = text.indexOf("\n", position + 2);
				position = newline < 0 ? text.length : newline;
				result.push(file.span(file.byteOffsetForStringOffset(start), file.byteOffsetForStringOffset(position)));
			} else if (marker == "/*") {
				var close = text.indexOf("*/", position + 2);
				position = close < 0 ? text.length : close + 2;
				result.push(file.span(file.byteOffsetForStringOffset(start), file.byteOffsetForStringOffset(position)));
			} else
				position++;
		}
		return result;
	}

	static function addConditionalFolds(file:compiler.Source.SourceFile, folds:Array<FoldingRegion>, containers:Array<SourceSpan>,
			?token:CancellationToken):Void {
		var source = file.text, offset = 0, stack:Array<Int> = [];
		while (offset < source.length) {
			if (token != null)
				token.check();
			var newline = source.indexOf("\n", offset),
				end = newline < 0 ? source.length : newline + 1,
				line = StringTools.trim(source.substring(offset, end));
			if (StringTools.startsWith(line, "#if"))
				stack.push(offset);
			else if (StringTools.startsWith(line, "#end") && stack.length > 0) {
				var span = file.span(file.byteOffsetForStringOffset(stack.pop()), file.byteOffsetForStringOffset(end));
				folds.push({span: span, kind: "region"});
				containers.push(span);
			}
			offset = end;
		}
	}

	function addWorkspaceSymbol(result:Array<WorkspaceSymbol>, state:ModuleState, name:String, kind:String, container:Null<String>, detail:String,
			span:SourceSpan):Void {
		var documentation = documentationFor(state, span);
		result.push({
			identity: state.name + ":" + kind + ":" + (container == null ? "" : container + ".") + name,
			name: name,
			kind: kind,
			container: container,
			detail: detail,
			path: state.source.path,
			span: span,
			revision: state.revision,
			documentation: documentation.markdown,
			deprecated: documentation.deprecated
		});
	}

	static function tagResults<T>(results:Array<T>, state:ModuleState):Void {
		var snapshot = editorSnapshot(state),
			revision = snapshot == null ? state.lastGoodRevision : snapshot.revision,
			stale = snapshot == null || snapshot.stale;
		for (result in results) {
			Reflect.setField(result, "revision", revision);
			Reflect.setField(result, "stale", stale);
		}
	}

	static function snapshotRevision(state:ModuleState):Int
		return editorSnapshot(state) == null ? state.lastGoodRevision : editorSnapshot(state).revision;

	function stateFor(path:String):Null<ModuleState>
		return compiler.modules.get(ModulePath.fromFile(path));

	static function editorSnapshot(state:ModuleState):Null<EditorSnapshot> {
		if (state.ast != null)
			return {
				source: state.source,
				tokens: state.tokens,
				ast: state.ast,
				semanticModel: state.semanticModel,
				revision: state.revision,
				stale: false,
				recovered: false,
				confidence: EditorSnapshotConfidence.Exact
			};

		if (state.recoveredAst != null)
			return {
				source: state.source,
				tokens: state.recoveredTokens,
				ast: state.recoveredAst,
				semanticModel: state.recoveredSemanticModel,
				revision: state.revision,
				stale: false,
				recovered: true,
				confidence: EditorSnapshotConfidence.RecoveredPartial
			};

		if (state.lastGoodAst != null && state.lastGoodSource != null && state.lastGoodSemanticModel != null)
			return {
				source: state.lastGoodSource,
				tokens: state.lastGoodTokens,
				ast: state.lastGoodAst,
				semanticModel: state.lastGoodSemanticModel,
				revision: state.lastGoodRevision,
				stale: true,
				recovered: false,
				confidence: EditorSnapshotConfidence.LastGood
			};

		return null;
	}

	static function effectiveAst(state:ModuleState):Null<compiler.syntax.Ast.AstProgram> {
		var snapshot = editorSnapshot(state);
		return snapshot == null ? null : snapshot.ast;
	}

	static function effectiveTokens(state:ModuleState):Null<Array<compiler.syntax.Token>> {
		var snapshot = editorSnapshot(state);
		return snapshot == null ? null : snapshot.tokens;
	}

	static function effectiveSemanticModel(state:ModuleState):Null<compiler.semantic.SemanticModel> {
		var snapshot = editorSnapshot(state);
		return snapshot == null ? null : snapshot.semanticModel;
	}

	static function identifierPrefix(source:SourceFile, position:Int):String {
		var end = position < 0 ? 0 : position > source.bytes.length ? source.bytes.length : position, start = end;
		while (start > 0 && isIdentifierPart(source.bytes.get(start - 1)))
			start--;
		return source.slice(start, end);
	}

	static function memberQualifier(source:SourceFile, position:Int):Null<String> {
		var end = position < 0 ? 0 : position > source.bytes.length ? source.bytes.length : position, start = end;
		while (start > 0 && isIdentifierPart(source.bytes.get(start - 1)))
			start--;
		if (start == 0 || source.bytes.get(start - 1) != ".".code)
			return null;
		var qualifierEnd = start - 1, qualifierStart = qualifierEnd;
		while (qualifierStart > 0 && isIdentifierPart(source.bytes.get(qualifierStart - 1)))
			qualifierStart--;
		return source.slice(qualifierStart, qualifierEnd);
	}

	static inline function isIdentifierPart(code:Int):Bool
		return (code >= 65 && code <= 90) || (code >= 97 && code <= 122) || (code >= 48 && code <= 57) || code == 95;

	static inline function isIdentifierStart(code:Int):Bool
		return (code >= 65 && code <= 90) || (code >= 97 && code <= 122) || code == 95;

	static function typeName(type:AstType):String
		return switch type {
			case ErrorType(_): "_";
			case IntType: "Int";
			case BoolType: "Bool";
			case FloatType: "Float";
			case StringType: "String";
			case VoidType: "Void";
			case InferredType: "_";
			case NativeAbstractType(declaration, tag): '$declaration<"$tag">';
			case NamedType(name): name;
			case AppliedType(name, arguments): '$name<${[for (argument in arguments) typeName(argument)].join(",")}>';
			case ArrayType(element): 'Array<${typeName(element)}>';
			case MapType(key, value): 'Map<${typeName(key)},${typeName(value)}>';
			case NullableType(element): 'Null<${typeName(element)}>';
			case FunctionType(arguments, result): '(${[for (argument in arguments) typeName(argument)].join(",")})->${typeName(result)}';
			case AnonymousType(fields): '{${[for (field in fields) (field.optional ? "?" : "") + field.name + ":" + typeName(field.type)].join(",")}}';
		};

	static function typeNameSubstituted(type:Null<AstType>, substitutions:Map<String, String>):String {
		if (type == null)
			return "_";

		return switch type {
			case NamedType(name): substitutions.exists(name) ? substitutions.get(name) : name;
			case AppliedType(name, arguments): '$name<${[for (argument in arguments) typeNameSubstituted(argument, substitutions)].join(",")}>';
			case ArrayType(element): 'Array<${typeNameSubstituted(element, substitutions)}>';
			case MapType(key, value): 'Map<${typeNameSubstituted(key, substitutions)},${typeNameSubstituted(value, substitutions)}>';
			case NullableType(element): 'Null<${typeNameSubstituted(element, substitutions)}>';
			case FunctionType(arguments, result): '(${[for (argument in arguments) typeNameSubstituted(argument, substitutions)].join(",")})->${typeNameSubstituted(result, substitutions)}';
			case AnonymousType(fields): '{${[for (field in fields) (field.optional ? "?" : "") + field.name + ":" + typeNameSubstituted(field.type, substitutions)].join(",")}}';
			default: typeName(type);
		};
	}

	function compilerTypeFromAst(type:AstType, substitutions:Map<String, String>):CompilerType {
		return switch type {
			case IntType: TInt;
			case BoolType: TBool;
			case FloatType: TFloat;
			case StringType: TString;
			case VoidType: TVoid;
			case NamedType(name): compilerTypeFromName(substitutions.exists(name) ? substitutions.get(name) : name);
			case AppliedType(name, arguments): TInstance(nominalKindFor(name), name, [for (argument in arguments) compilerTypeFromAst(argument, substitutions)]);
			case ArrayType(element): TArray(compilerTypeFromAst(element, substitutions));
			case MapType(key, value): TMap(compilerTypeFromAst(key, substitutions), compilerTypeFromAst(value, substitutions));
			case NullableType(element): TNullable(compilerTypeFromAst(element, substitutions));
			default: TUnknown;
		};
	}

	function compilerTypeFromName(name:String):CompilerType
		return switch name {
			case "Int": TInt;
			case "Bool": TBool;
			case "Float": TFloat;
			case "String": TString;
			case "Void": TVoid;
			default: TInstance(nominalKindFor(name), name, []);
		};

	function nominalKindFor(name:String):NominalKind {
		for (state in compiler.modules) {
			var ast = effectiveAst(state);
			if (ast == null)
				continue;
			for (interfaceDecl in ast.interfaces)
				if (interfaceDecl.name == name)
					return Interface;
			for (classDecl in ast.classes)
				if (classDecl.name == name)
					return Class;
		}
		return Class;
	}

	static function compilerTypeName(type:CompilerType):String
		return switch type {
			case TInt: "Int";
			case TInt64: "haxe.Int64";
			case TFloat: "Float";
			case TBool: "Bool";
			case TString: "String";
			case TUnknown: "Unknown";
			case TError: "Error";
			case TVoid: "Void";
			case TArray(element): 'Array<${compilerTypeName(element)}>';
			case TIterator(element): 'Iterator<${compilerTypeName(element)}>';
			case TMap(key, value): 'Map<${compilerTypeName(key)},${compilerTypeName(value)}>';
			case TNullable(element): 'Null<${compilerTypeName(element)}>';
			case TTypeParameter(_, name): name;
			case TInstance(_, name, arguments): arguments.length == 0 ? name : name
					+ "<"
					+ [for (argument in arguments) compilerTypeName(argument)].join(",") + ">";
			case TFunction(arguments, result): "(" + [for (argument in arguments) compilerTypeName(argument)].join(",") + ")->" + compilerTypeName(result);
			default: Std.string(type);
		};
}
