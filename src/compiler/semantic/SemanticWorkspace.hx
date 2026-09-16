package compiler.semantic;

import compiler.Source.SourceSpan;
import compiler.modules.ModuleState;
import compiler.modules.EditorWorkspaceView;
import compiler.types.DeclarationIndex.DeclarationKind;
import compiler.types.Type.CompilerType;
import compiler.types.Type.NominalKind;
import compiler.syntax.Ast.AstProgram;
import compiler.syntax.Ast.AstType;
import compiler.semantic.SemanticIndex.IndexedSemanticSymbol;
import compiler.semantic.SemanticIndex.SemanticSymbolId;
import compiler.semantic.SemanticIndex.SemanticSignatureInfo;
import compiler.semantic.SemanticIndex.SemanticCallEdge;
import compiler.service.CancellationToken;

/** A declaration resolved against the effective snapshots of a module workspace. */
typedef WorkspaceDeclaration = {
	final state:ModuleState;
	final key:String;
	final span:SourceSpan;
}

typedef ImportableSymbol = {
	final state:ModuleState;
	final symbol:IndexedSemanticSymbol;
	final importPath:String;
}

/** Instance member candidate exposed to editor queries. */
typedef EditorMember = {
	final name:String;
	final kind:String;
	final detail:String;
}

/** A lookup either identifies one declaration, no declaration, or an ambiguous set. */
enum WorkspaceResolution {
	Resolved(declaration:WorkspaceDeclaration);
	Ambiguous(declarations:Array<WorkspaceDeclaration>);
	Missing;
}

/** Shared cross-module name and member resolution over current or last-good models. */
class SemanticWorkspace {
	final modules:Map<String, ModuleState>;
	final symbolResolutionIndex:Map<String, Null<SemanticSymbolId>> = [];
	final typeResolutionIndex:Map<String, Null<SemanticSymbolId>> = [];
	final enumCaseResolutionCache:Map<String, Null<SemanticSymbolId>> = [];
	var resolutionIndexesValid = false;

	public function new(modules:Map<String, ModuleState>)
		this.modules = modules;

	public function global(from:ModuleState, name:String):Null<WorkspaceDeclaration> {
		return switch globalResolution(from, name) {
			case Resolved(declaration): declaration;
			case Ambiguous(_), Missing: null;
		};
	}

	public function globalResolution(from:ModuleState, name:String):WorkspaceResolution {
		var local = declarationsIn(from, name);
		if (local.length == 1)
			return Resolved(local[0]);
		if (local.length > 1)
			return Ambiguous(local);
		var matches:Array<WorkspaceDeclaration> = [];
		for (dependency in from.dependencies) {
			if (modules.exists(dependency)) {
				var state = modules.get(dependency);
				for (declaration in declarationsIn(state, name))
					if (!contains(matches, declaration))
						matches.push(declaration);
			}
		}
		return matches.length == 0 ? Missing : matches.length == 1 ? Resolved(matches[0]) : Ambiguous(matches);
	}

	public function member(type:CompilerType, name:String):Null<WorkspaceDeclaration>
		return memberInner(type, name, []);

	/** Resolve an inherited or direct member to its authoritative semantic identity. */
	public function memberSymbolId(type:CompilerType, name:String):Null<SemanticSymbolId> {
		var declaration = member(type, name);
		if (declaration == null)
			return null;
		var model = effectiveModel(declaration.state);
		if (model == null)
			return null;
		for (symbol in model.index.symbols)
			if (sameSpan(symbol.declaration, declaration.span))
				return symbol.id;
		return null;
	}

	public function resolveSymbolId(name:String):Null<SemanticSymbolId> {
		ensureResolutionIndexes();
		var direct = symbolResolutionIndex.get(name);
		if (direct != null || symbolResolutionIndex.exists(name))
			return direct;
		var separator = name.lastIndexOf(".");
		return separator < 1 ? null : resolveMemberSymbolId(name.substring(0, separator), name.substring(separator + 1));
	}

	/**
	 * Resolve a qualified member even when it is inherited rather than declared
	 * directly on the named receiver type. This is intentionally authoritative:
	 * only a unique type identity and a unique member declaration are returned.
	 */
	public function resolveMemberSymbolId(owner:String, name:String):Null<SemanticSymbolId> {
		var typeId = resolveTypeSymbolId(owner),
			resolved = typeId == null ? null : indexedSymbol(typeId);
		if (resolved == null)
			return null;
		var type:CompilerType = switch resolved.symbol.kind {
			case DeclarationKind.Class: TInstance(NominalKind.Class, owner, []);
			case DeclarationKind.Interface: TInstance(NominalKind.Interface, owner, []);
			case DeclarationKind.Abstract: TAbstract(owner, [], TUnknown);
			default: return null;
		};
		return memberSymbolId(type, name);
	}

	public function resolveTypeSymbolId(name:String):Null<SemanticSymbolId> {
		ensureResolutionIndexes();
		return typeResolutionIndex.get(name);
	}

	/**
	 * Resolve a recovered editor name using the source module's visibility
	 * rules. The authoritative workspace index is deliberately global, so a
	 * short name from an unrelated module must not be enough to bind a recovery
	 * reference.
	 */
	public function editorResolveSymbolId(from:ModuleState, name:String, ?sourceProgram:AstProgram,
		?token:CancellationToken):Null<SemanticSymbolId> {
		if (name.indexOf(".") < 0) {
			var localFunction = editorTopLevelFunctionId(from, name, token);
			if (localFunction != null)
				return localFunction;
			var importedFunction = editorImportedFunctionMatches(from, sourceProgram, name, token);
			if (importedFunction.explicit || importedFunction.ids.length > 0)
				return uniqueIdentity(importedFunction.ids);
		}
		var qualifiedMember = editorQualifiedMemberSymbolId(from, name, sourceProgram, token);
		if (qualifiedMember != null)
			return qualifiedMember;
		var importedModuleFunction = editorImportedModuleFunction(from, name, sourceProgram, token);
		if (importedModuleFunction.matched)
			return uniqueIdentity(importedModuleFunction.ids);
		var importedMember = editorImportedMemberSymbolId(from, name, sourceProgram, token);
		if (importedMember != null)
			return importedMember;
		var qualifiedType = editorQualifiedTypeSymbolId(name, token);
		if (qualifiedType != null)
			return qualifiedType;
		var importedType = editorImportedTypeSymbolId(from, name, sourceProgram, token);
		if (importedType != null)
			return importedType;
		var matches:Array<SemanticSymbolId> = [];
		for (candidate in editorSymbolCandidates(from, name, token, sourceProgram)) {
			if (token != null)
				token.check();
			var resolved = editorSymbolById(candidate);
			if (resolved == null || (resolved.state != from && indexedSymbol(candidate) == null))
				continue;
			addUniqueIdentity(matches, candidate);
		}
		if (matches.length == 1)
			return matches[0];
		if (matches.length > 1)
			return null;
		var direct = resolveSymbolId(name);
		return direct != null && editorSymbolVisible(from, direct, sourceProgram, token) ? direct : null;
	}

	function editorTopLevelFunctionId(state:ModuleState, name:String, ?token:CancellationToken):Null<SemanticSymbolId> {
		var model = editorModel(state), matches:Array<SemanticSymbolId> = [];
		if (model == null)
			return null;
		for (fn in model.program.functions) {
			if (token != null)
				token.check();
			if (fn.name != name)
				continue;
			for (symbol in model.index.symbols)
				if (symbol.kind == DeclarationKind.Function && sameSpan(symbol.declaration, fn.span))
					addUniqueIdentity(matches, symbol.id);
		}
		return uniqueIdentity(matches);
	}

	function editorImportedFunctionMatches(from:ModuleState, sourceProgram:Null<AstProgram>, name:String,
		?token:CancellationToken):{explicit:Bool, ids:Array<SemanticSymbolId>} {
		var model = editorModel(from),
			program = sourceProgram == null && model != null ? model.program : sourceProgram,
			result:Array<SemanticSymbolId> = [],
			explicit = false,
			blockedByModuleAlias = false;
		if (program == null)
			return {explicit: false, ids: result};
		for (importPath in program.imports) {
			if (token != null)
				token.check();
			if (isWildcardImport(importPath))
				continue;
			var importTarget = editorImportTarget(importPath),
				aliasedModule = false;
			for (_alias => path in program.importAliases)
				if (path == importPath && importTarget != null && importTarget.name == importPath)
					aliasedModule = true;
			if (aliasedModule) {
				// A module alias exposes its functions only through the qualifier
				// (for example `S.answer`). Remember the name so the final global
				// fallback cannot accidentally make `answer` callable as well.
				if (importTarget != null && editorTopLevelFunctionIds(importTarget, name, token).length > 0)
					blockedByModuleAlias = true;
				continue;
			}
			var target = editorImportTarget(importPath);
			if (target == null)
				continue;
			var ids = editorTopLevelFunctionIds(target, name, token);
			for (id in ids)
				if (target == from || indexedSymbol(id) != null)
					addUniqueIdentity(result, id);
			if (result.length > 0) {
				explicit = true;
			}
		}
		for (alias => importPath in program.importAliases) {
			if (token != null)
				token.check();
			if (alias != name)
				continue;
			var target = editorImportTarget(importPath);
			// An alias of a module is used as a qualifier (M.add), while an
			// alias of a declaration (Math.add as sum) is callable directly.
			if (target == null || importPath == target.name)
				continue;
			for (id in editorTopLevelFunctionIds(target, moduleSourceName(importPath), token))
				if (target == from || indexedSymbol(id) != null)
					addUniqueIdentity(result, id);
			if (result.length > 0)
				explicit = true;
		}
		if (explicit)
			return {explicit: true, ids: result};
		if (blockedByModuleAlias)
			return {explicit: true, ids: result};
		for (importPath in program.imports) {
			if (token != null)
				token.check();
			if (!isWildcardImport(importPath))
				continue;
			var packageName = importPath.substring(0, importPath.length - 2);
			for (state in orderedStates()) {
				if (token != null)
					token.check();
				var candidateModel = editorModel(state),
					candidatePackage = candidateModel == null || candidateModel.program.packageName == null ? null
						: Std.string(candidateModel.program.packageName);
				if (candidateModel == null || candidatePackage != packageName)
					continue;
				for (id in editorTopLevelFunctionIds(state, name, token))
					if (state == from || indexedSymbol(id) != null)
						addUniqueIdentity(result, id);
			}
		}
		return {explicit: false, ids: result};
	}

	/** Resolve a top-level function through a module qualifier, including aliases. */
	function editorImportedModuleFunction(from:ModuleState, name:String, sourceProgram:Null<AstProgram>,
		?token:CancellationToken):{matched:Bool, ids:Array<SemanticSymbolId>} {
		var separator = name.indexOf("."),
			result:Array<SemanticSymbolId> = [];
		if (separator < 1)
			return {matched: false, ids: result};
		var model = editorModel(from),
			program = sourceProgram == null && model != null ? model.program : sourceProgram;
		if (program == null)
			return {matched: false, ids: result};
		var qualifier = name.substring(0, separator),
			memberName = name.substring(separator + 1, name.length);
		for (importPath in program.imports) {
			if (token != null)
				token.check();
			if (isWildcardImport(importPath) || editorImportQualifier(program, importPath) != qualifier)
				continue;
			var target = editorImportTarget(importPath);
			// Only an imported module exposes its top-level functions through a
			// qualifier. A path below the module names a specific declaration.
			if (target == null || target.name != importPath)
				continue;
			for (id in editorTopLevelFunctionIds(target, memberName, token))
				if (target == from || indexedSymbol(id) != null)
					addUniqueIdentity(result, id);
		}
		for (importPath in program.imports) {
			if (token != null)
				token.check();
			if (!isWildcardImport(importPath))
				continue;
			var packageName = importPath.substring(0, importPath.length - 2),
				candidate = packageName + "." + qualifier,
				target = modules.get(candidate);
			if (target == null)
				continue;
			var targetModel = editorModel(target),
				targetPackage = targetModel == null || targetModel.program.packageName == null ? null
					: Std.string(targetModel.program.packageName);
			if (targetModel == null || targetPackage != packageName)
				continue;
			for (id in editorTopLevelFunctionIds(target, memberName, token))
				if (target == from || indexedSymbol(id) != null)
					addUniqueIdentity(result, id);
		}
		return {matched: result.length > 0, ids: result};
	}

	function editorTopLevelFunctionIds(state:ModuleState, name:String, ?token:CancellationToken):Array<SemanticSymbolId> {
		var model = editorModel(state), result:Array<SemanticSymbolId> = [];
		if (model == null)
			return result;
		for (fn in model.program.functions) {
			if (token != null)
				token.check();
			if (fn.name != name)
				continue;
			for (symbol in model.index.symbols)
				if (symbol.kind == DeclarationKind.Function && sameSpan(symbol.declaration, fn.span))
					addUniqueIdentity(result, symbol.id);
		}
		return result;
	}

	static function uniqueIdentity(ids:Array<SemanticSymbolId>):Null<SemanticSymbolId>
		return ids.length == 1 ? ids[0] : null;

	/** Resolve a recovered type name without bypassing editor visibility. */
	public function editorResolveTypeSymbolId(from:ModuleState, name:String, ?sourceProgram:AstProgram,
		?token:CancellationToken):Null<SemanticSymbolId> {
		var qualifiedType = editorQualifiedTypeSymbolId(name, token);
		if (qualifiedType != null)
			return qualifiedType;
		var importedType = editorImportedTypeSymbolId(from, name, sourceProgram, token);
		if (importedType != null)
			return importedType;
		var matches:Array<SemanticSymbolId> = [];
		for (candidate in editorSymbolCandidates(from, name, token, sourceProgram)) {
			if (token != null)
				token.check();
			var resolved = editorSymbolById(candidate);
			if (resolved == null || !isTypeKind(resolved.symbol.kind)
				|| (resolved.state != from && indexedSymbol(candidate) == null))
				continue;
			addUniqueIdentity(matches, candidate);
		}
		if (matches.length == 1)
			return matches[0];
		if (matches.length > 1)
			return null;
		var direct = resolveTypeSymbolId(name);
		return direct != null && editorSymbolVisible(from, direct, sourceProgram, token) ? direct : null;
	}

	/** Whether an existing identity is visible from a recovered editor module. */
	public function editorSymbolVisible(from:ModuleState, id:SemanticSymbolId, ?sourceProgram:AstProgram,
		?token:CancellationToken):Bool {
		if (token != null)
			token.check();
		var resolved = editorSymbolById(id);
		if (resolved == null || resolved.state == from)
			return resolved != null;
		var model = editorModel(from),
			packageName = sourceProgram != null && sourceProgram.packageName != null ? Std.string(sourceProgram.packageName)
				: model == null || model.program.packageName == null ? null : Std.string(model.program.packageName);
		return editorModuleVisible(from, resolved.state, packageName, sourceProgram);
	}

	function ensureResolutionIndexes():Void {
		if (resolutionIndexesValid)
			return;
		symbolResolutionIndex.clear();
		typeResolutionIndex.clear();
		for (state in orderedStates()) {
			var model = effectiveModel(state);
			if (model == null)
				continue;
			var packagePrefix = model.program.packageName == null ? "" : Std.string(model.program.packageName) + ".";
			for (symbol in model.index.symbols) {
				addResolutionCandidate(symbolResolutionIndex, symbol.name, symbol.id);
				addResolutionCandidate(symbolResolutionIndex, state.name + "." + symbol.name, symbol.id);
				if (packagePrefix != "")
					addResolutionCandidate(symbolResolutionIndex, packagePrefix + symbol.name, symbol.id);
				if (isTypeKind(symbol.kind)) {
					addResolutionCandidate(typeResolutionIndex, symbol.name, symbol.id);
					addResolutionCandidate(typeResolutionIndex, state.name + "." + symbol.name, symbol.id);
					if (packagePrefix != "")
						addResolutionCandidate(typeResolutionIndex, packagePrefix + symbol.name, symbol.id);
				}
			}
		}
		resolutionIndexesValid = true;
	}

	static function addResolutionCandidate(index:Map<String, Null<SemanticSymbolId>>, name:String, id:SemanticSymbolId):Void {
		if (!index.exists(name))
			index.set(name, id);
		else if (index.get(name) != id)
			index.set(name, null);
	}

	static function isTypeKind(kind:DeclarationKind):Bool
		return kind == DeclarationKind.Alias || kind == DeclarationKind.Enum || kind == DeclarationKind.Abstract || kind == DeclarationKind.Interface
			|| kind == DeclarationKind.Class;

	public function resolveEnumCaseId(enumName:String, index:Int):Null<SemanticSymbolId> {
		if (index < 0)
			return null;
		var cacheKey = enumName + ":" + index;
		if (enumCaseResolutionCache.exists(cacheKey))
			return enumCaseResolutionCache.get(cacheKey);
		var matches:Array<SemanticSymbolId> = [];
		for (state in orderedStates()) {
			var model = effectiveModel(state);
			if (model == null)
				continue;
			var packagePrefix = model.program.packageName == null ? "" : Std.string(model.program.packageName) + ".";
			for (declaration in model.program.enums)
				if ((declaration.name == enumName || packagePrefix + declaration.name == enumName) && index < declaration.cases.length) {
					var symbolName = declaration.name + "." + declaration.cases[index].name;
					for (symbol in model.index.symbols)
						if (symbol.name == symbolName)
							matches.push(symbol.id);
				}
		}
		var result = matches.length == 1 ? matches[0] : null;
		enumCaseResolutionCache.set(cacheKey, result);
		return result;
	}

	/**
	 * Resolve a recovered enum case using the source module's visible editor
	 * modules. A global enum-name lookup is not sufficient here: an unrelated
	 * package may declare an enum with the same short name while the current
	 * package has an unambiguous declaration.
	 */
	public function editorResolveEnumCaseId(from:ModuleState, enumName:String, index:Int,
		?sourceProgram:AstProgram, ?token:CancellationToken):Null<SemanticSymbolId> {
		if (index < 0)
			return null;
		var fromModel = editorModel(from),
			packageName = sourceProgram != null && sourceProgram.packageName != null ? Std.string(sourceProgram.packageName)
				: fromModel == null || fromModel.program.packageName == null ? null : Std.string(fromModel.program.packageName),
			matches:Array<SemanticSymbolId> = [];
		for (state in orderedStates()) {
			if (token != null)
				token.check();
			var model = editorModel(state);
			if (model == null || state != from && !editorModuleVisible(from, state, packageName, sourceProgram))
				continue;
			var packagePrefix = model.program.packageName == null ? "" : Std.string(model.program.packageName) + ".";
			for (declaration in model.program.enums) {
				if (token != null)
					token.check();
				if (declaration.name != enumName && packagePrefix + declaration.name != enumName)
					continue;
				if (index >= declaration.cases.length)
					continue;
				var symbolName = declaration.name + "." + declaration.cases[index].name;
				for (symbol in model.index.symbols)
					if (symbol.name == symbolName) {
						addUniqueIdentity(matches, symbol.id);
					}
			}
		}
		return matches.length == 1 ? matches[0] : null;
	}

	public function invalidateResolutionCache():Void {
		resolutionIndexesValid = false;
		symbolResolutionIndex.clear();
		typeResolutionIndex.clear();
		enumCaseResolutionCache.clear();
	}

	public function indexedSymbol(id:SemanticSymbolId):Null<{state:ModuleState, symbol:IndexedSemanticSymbol}> {
		for (state in orderedStates()) {
			var model = effectiveModel(state),
				symbol = model == null ? null : model.index.symbol(id);
			if (symbol != null)
				return {state: state, symbol: symbol};
		}
		return null;
	}

	/** Resolve a symbol for an editor query without publishing recovery globally. */
	public function editorSymbol(state:ModuleState, id:SemanticSymbolId):Null<{state:ModuleState, symbol:IndexedSemanticSymbol}> {
		var recovered = EditorWorkspaceView.currentRecovered(state);
		if (EditorWorkspaceView.currentExact(state) == null && recovered != null && recovered.semanticModel != null) {
			var symbol = recovered.semanticModel.index.symbol(id);
			if (symbol != null)
				return {state: state, symbol: symbol};
		}
		var indexed = indexedSymbol(id);
		if (indexed != null)
			return indexed;
		if (recovered != null && recovered.semanticModel != null) {
			var recoveredSymbol = recovered.semanticModel.index.symbol(id);
			if (recoveredSymbol != null)
				return {state: state, symbol: recoveredSymbol};
		}
		return null;
	}

	/** Resolve a hierarchy item from current editor models without publishing them. */
	public function editorSymbolById(id:SemanticSymbolId):Null<{state:ModuleState, symbol:IndexedSemanticSymbol}> {
		for (state in orderedStates()) {
			var model = editorModel(state),
				symbol = model == null ? null : model.index.symbol(id);
			if (symbol != null)
				return {state: state, symbol: symbol};
		}
		return null;
	}

	/**
	 * Return the canonical package-qualified name for an authoritative type.
	 *
	 * Recovered typing may encounter a type through a local alias or import
	 * spelling. Keeping the declaration's package identity on the temporary
	 * CompilerType lets member lookup resolve the same authoritative symbols as
	 * exact typing, without publishing any recovered declaration globally.
	 */
	public function editorTypeName(id:SemanticSymbolId):Null<String> {
		var resolved = editorSymbolById(id),
			model = resolved == null ? null : editorModel(resolved.state);
		if (resolved == null || model == null || !isTypeKind(resolved.symbol.kind)
			|| resolved.symbol.kind == DeclarationKind.Alias)
			return null;
		for (decl in model.program.classes)
			if (sameSpan(decl.span, resolved.symbol.declaration))
				return qualifiedType(model, decl.name);
		for (decl in model.program.interfaces)
			if (sameSpan(decl.span, resolved.symbol.declaration))
				return qualifiedType(model, decl.name);
		for (decl in model.program.abstracts)
			if (sameSpan(decl.span, resolved.symbol.declaration))
				return qualifiedType(model, decl.name);
		for (decl in model.program.enums)
			if (sameSpan(decl.span, resolved.symbol.declaration))
				return qualifiedType(model, decl.name);
		return null;
	}

	public function indexedSignature(id:SemanticSymbolId):Null<SemanticSignatureInfo> {
		for (state in orderedStates()) {
			var model = effectiveModel(state),
				signature = model == null ? null : model.index.signature(id);
			if (signature != null)
				return signature;
		}
		return null;
	}

	/** Read a signature from the current editor model when it exists. */
	public function editorSignature(state:ModuleState, id:SemanticSymbolId):Null<SemanticSignatureInfo> {
		var recovered = EditorWorkspaceView.currentRecovered(state);
		if (EditorWorkspaceView.currentExact(state) == null && recovered != null && recovered.semanticModel != null) {
			var signature = recovered.semanticModel.index.signature(id);
			if (signature != null)
				return signature;
		}
		return indexedSignature(id);
	}

	/** Read a hierarchy signature from current editor models without publishing them. */
	public function editorSignatureById(id:SemanticSymbolId):Null<SemanticSignatureInfo> {
		for (state in orderedStates()) {
			var model = editorModel(state),
				signature = model == null ? null : model.index.signature(id);
			if (signature != null)
				return signature;
		}
		return null;
	}

	public function indexedLocations(id:SemanticSymbolId, ?token:CancellationToken, ?exclude:ModuleState):Array<{state:ModuleState, span:SourceSpan}> {
		var result = [];
		for (state in orderedStates()) {
			if (token != null)
				token.check();
			if (exclude != null && state == exclude)
				continue;
			var model = effectiveModel(state);
			if (model != null)
				for (span in model.index.locations(id))
					result.push({state: state, span: span});
		}
		return result;
	}

	/**
	 * Collect references from current editor models without using recovery data
	 * as authoritative workspace state. A recovered location is eligible only
	 * when its identity is already authoritative elsewhere, or when it belongs
	 * to the queried editor module itself.
	 */
	public function editorLocations(state:ModuleState, id:SemanticSymbolId, ?token:CancellationToken):Array<{state:ModuleState, span:SourceSpan}> {
		var result:Array<{state:ModuleState, span:SourceSpan}> = [],
			authoritativeSymbol = indexedSymbol(id),
			authoritative = authoritativeSymbol != null;
		for (candidate in orderedStates()) {
			if (token != null)
				token.check();
			if (candidate == state)
				continue;
			var exact = EditorWorkspaceView.currentExact(candidate),
				recovered = EditorWorkspaceView.currentRecovered(candidate);
			if (exact != null) {
				if (exact.semanticModel != null)
					for (span in exact.semanticModel.index.locations(id))
						addLocation(result, candidate, span);
				if (authoritative && exact.semanticModel != null
					&& exact.semanticModel.index.symbol(id) == null
					&& recovered != null
					&& recovered.semanticModel != null) {
					for (span in recovered.semanticModel.index.locations(id)) {
						if (token != null)
							token.check();
						addLocation(result, candidate, span);
					}
				}
				continue;
			}
			if (recovered != null && recovered.semanticModel != null && authoritative)
				for (span in recovered.semanticModel.index.locations(id)) {
					if (token != null)
						token.check();
					addLocation(result, candidate, span);
				}
		}
		var exact = EditorWorkspaceView.currentExact(state),
			recovered = EditorWorkspaceView.currentRecovered(state);
		if (exact != null) {
			if (exact.semanticModel != null)
				for (span in exact.semanticModel.index.locations(id))
					addLocation(result, state, span);
			// A valid source snapshot may not type an unreachable body, while its
			// current recovered model still contains references to the queried
			// identity. Merge those current-source locations even when the exact
			// model already contributed locations. Keep the existing same-module
			// guard so a recovered local cannot be merged into an exact symbol that
			// the current semantic model owns under the same identity.
			var exactSymbol = exact.semanticModel == null ? null : exact.semanticModel.index.symbol(id);
			if (exact.semanticModel != null
					&& (exactSymbol == null || authoritativeSymbol != null && authoritativeSymbol.state != state)
					&& recovered != null
					&& recovered.semanticModel != null) {
					for (span in recovered.semanticModel.index.locations(id)) {
						if (token != null)
							token.check();
						addLocation(result, state, span);
					}
				}
		} else if (recovered != null && recovered.semanticModel != null)
			for (span in recovered.semanticModel.index.locations(id)) {
				if (token != null)
					token.check();
				addLocation(result, state, span);
			}
		return result;
	}

	static function addLocation(result:Array<{state:ModuleState, span:SourceSpan}>, state:ModuleState, span:SourceSpan):Void {
		for (existing in result)
			if (sameSpan(existing.span, span))
				return;
		result.push({state: state, span: span});
	}

	public function indexedCalls(?token:CancellationToken):Array<{state:ModuleState, edge:SemanticCallEdge}> {
		var result = [];
		for (state in orderedStates()) {
			if (token != null)
				token.check();
			var model = effectiveModel(state);
			if (model != null)
				for (edge in model.index.calls())
					result.push({state: state, edge: edge});
		}
		return result;
	}

	/** Call edges visible to an editor query, including current recovered models. */
	public function editorCalls(?token:CancellationToken):Array<{state:ModuleState, edge:SemanticCallEdge}> {
		var result = [];
		for (state in orderedStates()) {
			if (token != null)
				token.check();
			var model = editorModel(state);
			if (model != null)
				for (edge in model.index.calls())
					result.push({state: state, edge: edge});
		}
		return result;
	}

	/** Direct nominal parents visible to an editor query. */
	public function editorDirectTypeSupertypes(id:SemanticSymbolId, ?token:CancellationToken):Array<SemanticSymbolId> {
		var resolved = editorSymbolById(id), result:Array<SemanticSymbolId> = [];
		if (resolved == null || !isTypeKind(resolved.symbol.kind))
			return result;
		var model = editorModel(resolved.state),
			parents:Array<compiler.syntax.Ast.AstType> = [];
		if (model == null)
			return result;
		for (decl in model.program.classes)
			if (sameSpan(decl.span, resolved.symbol.declaration)) {
				if (decl.base != null)
					parents.push(decl.base);
				parents = parents.concat(decl.interfaces);
			}
		for (decl in model.program.interfaces)
			if (sameSpan(decl.span, resolved.symbol.declaration))
				parents = parents.concat(decl.bases);
		for (parent in parents) {
			if (token != null)
				token.check();
			var declaration = editorGlobal(resolved.state, ModuleCanonicalizer.astTypeName(parent)),
				symbol = declaration == null ? null : editorSymbolAt(editorModel(declaration.state), declaration.span);
			if (symbol != null)
				addTypeIdentity(result, symbol.id);
		}
		result.sort(function(left, right) return Reflect.compare(Std.string(left), Std.string(right)));
		return result;
	}

	/** Direct nominal children visible to an editor query. */
	public function editorDirectTypeSubtypes(id:SemanticSymbolId, ?token:CancellationToken):Array<SemanticSymbolId> {
		var resolved = editorSymbolById(id), result:Array<SemanticSymbolId> = [];
		if (resolved == null || !isTypeKind(resolved.symbol.kind))
			return result;
		for (state in orderedStates()) {
			if (token != null)
				token.check();
			var model = editorModel(state);
			if (model == null)
				continue;
			for (decl in model.program.classes) {
				var parents = decl.interfaces.copy();
				if (decl.base != null)
					parents.push(decl.base);
				if (hasDirectEditorParent(state, parents, id, token)) {
					var symbol = editorSymbolAt(model, decl.span);
					if (symbol != null)
						addTypeIdentity(result, symbol.id);
				}
			}
			for (decl in model.program.interfaces)
				if (hasDirectEditorParent(state, decl.bases, id, token)) {
					var symbol = editorSymbolAt(model, decl.span);
					if (symbol != null)
						addTypeIdentity(result, symbol.id);
				}
		}
		result.sort(function(left, right) return Reflect.compare(Std.string(left), Std.string(right)));
		return result;
	}

	/** Direct nominal parents of a class or interface declaration. */
	public function directTypeSupertypes(id:SemanticSymbolId, ?token:CancellationToken):Array<SemanticSymbolId> {
		var resolved = indexedSymbol(id), result:Array<SemanticSymbolId> = [];
		if (resolved == null || !isTypeKind(resolved.symbol.kind))
			return result;
		var model = effectiveModel(resolved.state),
			parents:Array<compiler.syntax.Ast.AstType> = [];
		if (model == null)
			return result;
		for (decl in model.program.classes)
			if (sameSpan(decl.span, resolved.symbol.declaration)) {
				if (decl.base != null)
					parents.push(decl.base);
				parents = parents.concat(decl.interfaces);
			}
		for (decl in model.program.interfaces)
			if (sameSpan(decl.span, resolved.symbol.declaration))
				parents = parents.concat(decl.bases);
		for (parent in parents) {
			if (token != null)
				token.check();
			var declaration = global(resolved.state, ModuleCanonicalizer.astTypeName(parent)),
				symbol = declaration == null ? null : symbolFor(declaration);
			if (symbol != null)
				addTypeIdentity(result, symbol.id);
		}
		result.sort(function(left, right) return Reflect.compare(Std.string(left), Std.string(right)));
		return result;
	}

	/** Direct nominal children of a class or interface declaration. */
	public function directTypeSubtypes(id:SemanticSymbolId, ?token:CancellationToken):Array<SemanticSymbolId> {
		var resolved = indexedSymbol(id), result:Array<SemanticSymbolId> = [];
		if (resolved == null || !isTypeKind(resolved.symbol.kind))
			return result;
		for (state in orderedStates()) {
			if (token != null)
				token.check();
			var model = effectiveModel(state);
			if (model == null)
				continue;
			for (decl in model.program.classes) {
				var parents = decl.interfaces.copy();
				if (decl.base != null)
					parents.push(decl.base);
				if (hasDirectParent(state, parents, id)) {
					var symbol = symbolAt(model, decl.span);
					if (symbol != null)
						addTypeIdentity(result, symbol.id);
				}
			}
			for (decl in model.program.interfaces)
				if (hasDirectParent(state, decl.bases, id)) {
					var symbol = symbolAt(model, decl.span);
					if (symbol != null)
						addTypeIdentity(result, symbol.id);
				}
		}
		result.sort(function(left, right) return Reflect.compare(Std.string(left), Std.string(right)));
		return result;
	}

	function hasDirectParent(state:ModuleState, parents:Array<compiler.syntax.Ast.AstType>, target:SemanticSymbolId):Bool {
		for (parent in parents) {
			var declaration = global(state, ModuleCanonicalizer.astTypeName(parent)),
				symbol = declaration == null ? null : symbolFor(declaration);
			if (symbol != null && symbol.id == target)
				return true;
		}
		return false;
	}

	function hasDirectEditorParent(state:ModuleState, parents:Array<compiler.syntax.Ast.AstType>, target:SemanticSymbolId,
		?token:CancellationToken):Bool {
		for (parent in parents) {
			if (token != null)
				token.check();
			var declaration = editorGlobal(state, ModuleCanonicalizer.astTypeName(parent)),
				symbol = declaration == null ? null : editorSymbolAt(editorModel(declaration.state), declaration.span);
			if (symbol != null && symbol.id == target)
				return true;
		}
		return false;
	}

	function editorGlobal(from:ModuleState, name:String):Null<WorkspaceDeclaration> {
		var local = editorDeclarationsIn(from, name);
		if (local.length == 1)
			return local[0];
		if (local.length > 1)
			return null;
		var matches:Array<WorkspaceDeclaration> = [];
		for (dependency in from.dependencies)
			if (modules.exists(dependency)) {
				var state = modules.get(dependency);
				for (declaration in editorDeclarationsIn(state, name))
					if (!contains(matches, declaration))
						matches.push(declaration);
			}
		var fromModel = editorModel(from),
			packageName = fromModel == null || fromModel.program.packageName == null ? null : Std.string(fromModel.program.packageName);
		for (state in orderedStates()) {
			if (state == from || !editorModuleVisible(from, state, packageName))
				continue;
			for (declaration in editorDeclarationsIn(state, name))
				if (!contains(matches, declaration))
					matches.push(declaration);
		}
		return matches.length == 1 ? matches[0] : null;
	}

	function editorModuleVisible(from:ModuleState, candidate:ModuleState, packageName:Null<String>, ?sourceProgram:AstProgram):Bool {
		var model = editorModel(from),
			program = sourceProgram == null && model != null ? model.program : sourceProgram,
			resolvedPackage = packageName == null && program != null && program.packageName != null ? Std.string(program.packageName) : packageName;
		var candidateModel = editorModel(candidate),
			candidatePackage = candidateModel == null || candidateModel.program.packageName == null ? null : Std.string(candidateModel.program.packageName),
			logicalCandidateName = candidatePackage == null ? candidate.name : candidatePackage + "." + moduleSourceName(candidate.name);
		if (resolvedPackage != null) {
			if (candidatePackage == resolvedPackage)
				return true;
		}
		if (program == null)
			return false;
		for (importPath in program.imports) {
			var wildcard = StringTools.endsWith(importPath, ".*"),
				prefix = wildcard ? importPath.substring(0, importPath.length - 2) : importPath;
			if (candidate.name == prefix || StringTools.startsWith(candidate.name, prefix + ".")
				|| logicalCandidateName == prefix || StringTools.startsWith(logicalCandidateName, prefix + ".")
				|| editorImportModule(importPath) == candidate.name)
				return true;
		}
		return false;
	}

	/** Resolve a source-level imported type, including secondary module types. */
	function editorImportedTypeSymbolId(from:ModuleState, name:String, ?sourceProgram:AstProgram,
		?token:CancellationToken):Null<SemanticSymbolId> {
		var model = editorModel(from),
			program = sourceProgram == null && model != null ? model.program : sourceProgram;
		if (program == null)
			return null;
		var matches:Array<SemanticSymbolId> = [];
		var explicitName = false;
		for (importPath in program.imports)
			if (!isWildcardImport(importPath) && editorImportQualifier(program, importPath) == name) {
				explicitName = true;
				addImportedTypeMatches(from, program, importPath, matches, token);
			}
		for (alias => importPath in program.importAliases)
			if (alias == name) {
				explicitName = true;
				addImportedTypeMatches(from, program, importPath, matches, token);
			}
		if (!explicitName)
			for (importPath in program.imports)
				if (isWildcardImport(importPath))
					addWildcardTypeMatches(from, program, importPath, name, matches, token);
		var unique:Array<SemanticSymbolId> = [];
		for (id in matches)
			if (unique.indexOf(id) < 0)
				unique.push(id);
		return unique.length == 1 ? unique[0] : null;
	}

	/** Resolve a type imported from all direct modules in a wildcard package. */
	function addWildcardTypeMatches(from:ModuleState, program:AstProgram, importPath:String, name:String,
		result:Array<SemanticSymbolId>, ?token:CancellationToken):Void {
		var packageName = importPath.substring(0, importPath.length - 2);
		for (state in orderedStates()) {
			if (token != null)
				token.check();
			var model = editorModel(state),
				candidatePackage = model == null || model.program.packageName == null ? null : Std.string(model.program.packageName);
			if (model == null || candidatePackage != packageName)
				continue;
			for (symbol in model.index.symbols) {
				if (token != null)
					token.check();
				if (isTypeKind(symbol.kind) && symbol.name == name
					&& editorSymbolVisible(from, symbol.id, program, token))
					addUniqueIdentity(result, symbol.id);
			}
		}
	}

	function addImportedTypeMatches(from:ModuleState, program:AstProgram, importPath:String,
		result:Array<SemanticSymbolId>, ?token:CancellationToken):Void {
		if (token != null)
			token.check();
		var target = editorImportTarget(importPath),
			model = target == null ? null : editorModel(target),
			typeName = target == null || model == null ? null : editorImportedTypeName(target, model, importPath);
		if (target == null || model == null || typeName == null)
			return;
		var id = editorTypeIdentityByName(typeName, token);
		if (id != null && editorSymbolVisible(from, id, program, token))
			result.push(id);
	}

	function editorImportedMemberSymbolId(from:ModuleState, name:String, ?sourceProgram:AstProgram,
		?token:CancellationToken):Null<SemanticSymbolId> {
		var separator = name.indexOf(".");
		if (separator < 1)
			return null;
		var qualifier = name.substring(0, separator),
			memberName = name.substring(separator + 1),
			typeId = editorImportedTypeSymbolId(from, qualifier, sourceProgram, token);
		if (typeId == null)
			return null;
		var resolved = editorSymbolById(typeId),
			canonical = editorTypeName(typeId);
		if (resolved == null || canonical == null)
			return null;
		return memberSymbolForType(resolved.symbol.kind, canonical, memberName, token);
	}

	function editorQualifiedMemberSymbolId(from:ModuleState, name:String, ?sourceProgram:AstProgram,
		?token:CancellationToken):Null<SemanticSymbolId> {
		var separator = name.lastIndexOf(".");
		while (separator > 0) {
			if (token != null)
				token.check();
			var receiverName = name.substring(0, separator),
				memberName = name.substring(separator + 1),
				typeId = editorQualifiedTypeSymbolId(receiverName, token);
			if (typeId != null) {
				var resolved = editorSymbolById(typeId),
					canonical = editorTypeName(typeId);
				if (resolved != null && canonical != null) {
					var member = memberSymbolForType(resolved.symbol.kind, canonical, memberName, token);
					if (member != null)
						return member;
				}
			}
			separator = receiverName.lastIndexOf(".");
		}
		return null;
	}

	function memberSymbolForType(kind:DeclarationKind, canonical:String, memberName:String, ?token:CancellationToken):Null<SemanticSymbolId> {
		return switch kind {
			case DeclarationKind.Class: memberSymbolId(TInstance(NominalKind.Class, canonical, []), memberName);
			case DeclarationKind.Interface: memberSymbolId(TInstance(NominalKind.Interface, canonical, []), memberName);
			case DeclarationKind.Enum: editorEnumCaseSymbolId(canonical, memberName, token);
			case DeclarationKind.Abstract: memberSymbolId(TAbstract(canonical, [], TUnknown), memberName);
			default: null;
		};
	}

	function editorEnumCaseSymbolId(canonical:String, memberName:String, ?token:CancellationToken):Null<SemanticSymbolId> {
		var matches:Array<SemanticSymbolId> = [];
		for (state in orderedStates()) {
			if (token != null)
				token.check();
			var model = editorModel(state);
			if (model == null)
				continue;
			var packagePrefix = model.program.packageName == null ? "" : Std.string(model.program.packageName) + ".";
			for (decl in model.program.enums) {
				if (token != null)
					token.check();
				if (packagePrefix + decl.name != canonical && decl.name != canonical)
					continue;
				for (caseDecl in decl.cases)
					if (caseDecl.name == memberName)
						for (symbol in model.index.symbols)
							if (symbol.kind == DeclarationKind.EnumCase && symbol.name == decl.name + "." + memberName)
								addUniqueIdentity(matches, symbol.id);
			}
		}
		return uniqueIdentity(matches);
	}

	function editorQualifiedTypeSymbolId(name:String, ?token:CancellationToken):Null<SemanticSymbolId> {
		if (token != null)
			token.check();
		var direct = editorTypeIdentityByName(name, token, false);
		if (direct != null)
			return direct;
		var target = editorImportTarget(name),
			model = target == null ? null : editorModel(target),
			typeName = target == null || model == null ? null : editorImportedTypeName(target, model, name);
		if (target == null || model == null || typeName == null)
			return null;
		return editorTypeIdentityByName(typeName, token, false);
	}

	/** Resolve a canonical type name from the current editor-visible models. */
	function editorTypeIdentityByName(name:String, ?token:CancellationToken, includeShort:Bool = true):Null<SemanticSymbolId> {
		var matches:Array<SemanticSymbolId> = [];
		for (state in orderedStates()) {
			if (token != null)
				token.check();
			var model = editorModel(state);
			if (model == null)
				continue;
			for (symbol in model.index.symbols) {
				if (token != null)
					token.check();
				if (!isTypeKind(symbol.kind))
					continue;
				var packagePrefix = model.program.packageName == null ? "" : Std.string(model.program.packageName) + ".",
					canonical = packagePrefix + symbol.name;
				if (canonical == name || includeShort && symbol.name == name)
					addUniqueIdentity(matches, symbol.id);
			}
		}
		return matches.length == 1 ? matches[0] : null;
	}

	function editorImportedTypeName(target:ModuleState, model:compiler.semantic.SemanticModel, importPath:String):Null<String> {
		var moduleName = target.name,
			nestedName = importPath == moduleName ? moduleSourceName(moduleName) : importPath.substring(moduleName.length + 1);
		for (decl in model.program.classes)
			if (moduleSourceName(decl.name) == nestedName)
				return canonicalEditorTypeName(model, decl.name);
		for (decl in model.program.interfaces)
			if (moduleSourceName(decl.name) == nestedName)
				return canonicalEditorTypeName(model, decl.name);
		for (decl in model.program.abstracts)
			if (moduleSourceName(decl.name) == nestedName)
				return canonicalEditorTypeName(model, decl.name);
		for (decl in model.program.enums)
			if (moduleSourceName(decl.name) == nestedName)
				return canonicalEditorTypeName(model, decl.name);
		for (decl in model.program.aliases)
			if (moduleSourceName(decl.name) == nestedName)
				return canonicalEditorTypeName(model, decl.name);
		return null;
	}

	static function canonicalEditorTypeName(model:compiler.semantic.SemanticModel, name:String):String {
		var packageName = model.program.packageName == null ? "" : Std.string(model.program.packageName);
		return packageName.length == 0 || StringTools.startsWith(name, packageName + ".") ? name : packageName + "." + name;
	}

	function editorImportTarget(importPath:String):Null<ModuleState> {
		var candidate = importPath;
		while (candidate.length > 0) {
			var state = modules.get(candidate);
			if (state != null)
				return state;
			var separator = candidate.lastIndexOf(".");
			if (separator < 0)
				break;
			candidate = candidate.substring(0, separator);
		}
		return null;
	}

	function editorImportModule(importPath:String):Null<String> {
		var target = editorImportTarget(importPath);
		return target == null ? null : target.name;
	}

	static function editorImportQualifier(program:AstProgram, importPath:String):String {
		for (alias => path in program.importAliases)
			if (path == importPath)
				return alias;
		return moduleSourceName(importPath);
	}

	function editorDeclarationsIn(state:ModuleState, name:String):Array<WorkspaceDeclaration> {
		var result:Array<WorkspaceDeclaration> = [],
			model = editorModel(state);
		if (model != null) {
			var kinds:Array<DeclarationKind> = [
				DeclarationKind.Alias,
				DeclarationKind.Function,
				DeclarationKind.Class,
				DeclarationKind.Interface,
				DeclarationKind.Enum,
				DeclarationKind.Abstract
			];
			for (kind in kinds) {
				var declaration = model.declarations.symbol(kind, name);
				if (declaration != null)
					result.push({state: state, key: declaration.id, span: declaration.span});
			}
		}
		return result;
	}

	function symbolFor(declaration:WorkspaceDeclaration):Null<IndexedSemanticSymbol> {
		var model = effectiveModel(declaration.state);
		return model == null ? null : symbolAt(model, declaration.span);
	}

	static function symbolAt(model:SemanticModel, span:SourceSpan):Null<IndexedSemanticSymbol> {
		for (symbol in model.index.symbols)
			if (sameSpan(symbol.declaration, span) && isTypeKind(symbol.kind))
				return symbol;
		return null;
	}

	static function addTypeIdentity(result:Array<SemanticSymbolId>, identity:SemanticSymbolId):Void {
		addUniqueIdentity(result, identity);
	}

	static function addUniqueIdentity(result:Array<SemanticSymbolId>, identity:SemanticSymbolId):Void {
		for (existing in result)
			if (existing == identity)
				return;
		result.push(identity);
	}

	public function implementations(id:SemanticSymbolId, ?token:CancellationToken):Array<WorkspaceDeclaration> {
		return collectImplementations(id, false, token);
	}

	/**
	 * Collect implementations for an editor query. The target must already be
	 * authoritative, but candidate classes may come from their current
	 * recovered editor models. This keeps edited implementation locations
	 * visible without publishing speculative declarations to the workspace.
	 */
	public function editorImplementations(id:SemanticSymbolId, ?token:CancellationToken):Array<WorkspaceDeclaration> {
		return collectImplementations(id, true, token);
	}

	function collectImplementations(id:SemanticSymbolId, editor:Bool, ?token:CancellationToken):Array<WorkspaceDeclaration> {
		var indexed = indexedSymbol(id);
		if (indexed == null)
			return [];
		var resolved = editor ? editorSymbolById(id) : indexed;
		if (resolved == null)
			return [];
		var owner:Null<String> = null,
			member:Null<String> = null,
			targetIsType = false;
		for (state in orderedStates()) {
			var model = editor ? editorModel(state) : effectiveModel(state);
			if (model == null)
				continue;
			for (decl in model.program.classes)
				if (sameSpan(decl.span, resolved.symbol.declaration)) {
					owner = qualifiedType(model, decl.name);
					targetIsType = true;
				} else
					for (method in decl.methods)
						if (sameSpan(method.span, resolved.symbol.declaration)) {
							owner = qualifiedType(model, decl.name);
							member = method.name;
						}
			for (decl in model.program.interfaces)
				if (sameSpan(decl.span, resolved.symbol.declaration)) {
					owner = qualifiedType(model, decl.name);
					targetIsType = true;
				} else
					for (method in decl.methods)
						if (sameSpan(method.span, resolved.symbol.declaration)) {
							owner = qualifiedType(model, decl.name);
							member = method.name;
						}
		}
		if (owner == null)
			return [];
		var result:Array<WorkspaceDeclaration> = [],
			seen:Map<String, Bool> = [];
		for (state in orderedStates()) {
			if (token != null)
				token.check();
			var model = editor ? editorModel(state) : effectiveModel(state);
			if (model == null)
				continue;
			for (decl in model.program.classes) {
				var identity = qualifiedType(model, decl.name);
				var derived = editor ? editorInheritsFrom(state, identity, owner, [], token) : inheritsFrom(identity, owner, []);
				if (identity == owner || !derived)
					continue;
				if (targetIsType)
					addImplementation(result, seen, state, 'class:${decl.name}', decl.span);
				else
					for (method in decl.methods)
						if (method.name == member)
							addImplementation(result, seen, state, 'class:${decl.name}:method:$member', method.span);
			}
		}
		result.sort(function(left, right) {
			var path = Reflect.compare(left.span.file.path, right.span.file.path);
			return path == 0 ? left.span.start - right.span.start : path;
		});
		return result;
	}

	function editorInheritsFrom(from:ModuleState, candidate:String, target:String, visiting:Map<String, Bool>,
		?token:CancellationToken):Bool {
		if (candidate == target)
			return true;
		if (visiting.exists(candidate))
			return false;
		visiting.set(candidate, true);
		for (state in orderedStates()) {
			if (token != null)
				token.check();
			var model = editorModel(state);
			if (model == null)
				continue;
			for (decl in model.program.classes)
				if (qualifiedType(model, decl.name) == candidate) {
					var parents = decl.interfaces.copy();
					if (decl.base != null)
						parents.push(decl.base);
					for (parent in parents) {
						if (token != null)
							token.check();
						var parentName = ModuleCanonicalizer.astTypeName(parent),
							parentIdentity = resolveEditorTypeIdentity(state, parentName);
						if (parentIdentity == target || editorInheritsFrom(state, parentIdentity, target, visiting, token))
							return true;
					}
				}
			for (decl in model.program.interfaces)
				if (qualifiedType(model, decl.name) == candidate)
					for (base in decl.bases) {
						if (token != null)
							token.check();
						var baseName = ModuleCanonicalizer.astTypeName(base),
							baseIdentity = resolveEditorTypeIdentity(state, baseName);
						if (baseIdentity == target || editorInheritsFrom(state, baseIdentity, target, visiting, token))
							return true;
					}
		}
		return false;
	}

	function resolveEditorTypeIdentity(from:ModuleState, name:String):String {
		var declaration = editorGlobal(from, name);
		if (declaration == null)
			return name;
		var model = editorModel(declaration.state);
		if (model == null)
			return name;
		for (decl in model.program.classes)
			if (sameSpan(decl.span, declaration.span))
				return qualifiedType(model, decl.name);
		for (decl in model.program.interfaces)
			if (sameSpan(decl.span, declaration.span))
				return qualifiedType(model, decl.name);
		return name;
	}

	function inheritsFrom(candidate:String, target:String, visiting:Map<String, Bool>):Bool {
		if (candidate == target)
			return true;
		if (visiting.exists(candidate))
			return false;
		visiting.set(candidate, true);
		for (state in orderedStates()) {
			var model = effectiveModel(state);
			if (model == null)
				continue;
			for (decl in model.program.classes)
				if (qualifiedType(model, decl.name) == candidate) {
					var parents = decl.interfaces.copy();
					if (decl.base != null)
						parents.push(decl.base);
					for (parent in parents) {
						var name = ModuleCanonicalizer.astTypeName(parent);
						if (typeNameMatches(name, target) || inheritsFrom(resolveTypeIdentity(state, name), target, visiting))
							return true;
					}
				}
			for (decl in model.program.interfaces)
				if (qualifiedType(model, decl.name) == candidate)
					for (base in decl.bases) {
						var name = ModuleCanonicalizer.astTypeName(base);
						if (typeNameMatches(name, target) || inheritsFrom(resolveTypeIdentity(state, name), target, visiting))
							return true;
					}
		}
		return false;
	}

	function resolveTypeIdentity(from:ModuleState, name:String):String {
		var declaration = global(from, name);
		if (declaration == null)
			return name;
		var model = effectiveModel(declaration.state);
		if (model == null)
			return name;
		for (decl in model.program.classes)
			if (decl.span.start == declaration.span.start && decl.span.end == declaration.span.end)
				return qualifiedType(model, decl.name);
		for (decl in model.program.interfaces)
			if (decl.span.start == declaration.span.start && decl.span.end == declaration.span.end)
				return qualifiedType(model, decl.name);
		return name;
	}

	static function qualifiedType(model:SemanticModel, name:String):String
		return ModuleCanonicalizer.qualifiedTypeName(model.program.packageName, name);

	static function typeNameMatches(name:String, target:String):Bool
		return name == target || name == target.substring(target.lastIndexOf(".") + 1);

	static function sameSpan(left:SourceSpan, right:SourceSpan):Bool
		return left.file.path == right.file.path && left.start == right.start && left.end == right.end;

	static function moduleSourceName(name:String):String {
		var separator = name.lastIndexOf(".");
		return separator < 0 ? name : name.substring(separator + 1);
	}

	static function isWildcardImport(path:String):Bool
		return path.length > 2 && StringTools.endsWith(path, ".*");

	static function addImplementation(result:Array<WorkspaceDeclaration>, seen:Map<String, Bool>, state:ModuleState, key:String, span:SourceSpan):Void {
		var identity = span.file.path + ":" + span.start + ":" + span.end;
		if (!seen.exists(identity)) {
			seen.set(identity, true);
			result.push({state: state, key: key, span: span});
		}
	}

	public function visibleSymbols(from:ModuleState, ?token:CancellationToken):Array<IndexedSemanticSymbol> {
		var visibleModules:Map<String, Bool> = [from.name => true],
			result:Array<IndexedSemanticSymbol> = [],
			seen:Map<String, Bool> = [];
		for (dependency in from.dependencies)
			visibleModules.set(dependency, true);
		for (state in orderedStates()) {
			if (token != null)
				token.check();
			if (!visibleModules.exists(state.name))
				continue;
			var model = effectiveModel(state);
			if (model != null)
				for (symbol in model.index.symbols) {
					// Type parameters are lexical declarations. This workspace-wide
					// list has no cursor scope, so exposing them here would make a
					// generic from one function appear in unrelated completions.
					if (symbol.kind == DeclarationKind.TypeParameter)
						continue;
					if (!seen.exists(symbol.id)) {
						seen.set(symbol.id, true);
						result.push(symbol);
					}
				}
		}
		result.sort(function(left, right) return Reflect.compare(left.name, right.name));
		return result;
	}

	/** Visible symbols for an editor query; recovered declarations are local to the query. */
	public function editorVisibleSymbols(from:ModuleState, ?token:CancellationToken):Array<IndexedSemanticSymbol> {
		var result:Array<IndexedSemanticSymbol> = [],
			seen:Map<String, Bool> = [];
		var recovered = EditorWorkspaceView.currentRecovered(from);
		if (EditorWorkspaceView.currentExact(from) == null && recovered != null && recovered.semanticModel != null)
			for (symbol in recovered.semanticModel.index.symbols)
				if (symbol.kind != DeclarationKind.TypeParameter) {
					seen.set(Std.string(symbol.id), true);
					result.push(symbol);
				}
		for (symbol in visibleSymbols(from, token))
			if (!seen.exists(Std.string(symbol.id))) {
				seen.set(Std.string(symbol.id), true);
				result.push(symbol);
			}
		result.sort(function(left, right) return Reflect.compare(left.name, right.name));
		return result;
	}

	/**
	 * Return visible top-level candidates for a recovered unresolved name.
	 * Candidates are evidence for tooling only; callers must still require a
	 * unique resolution before assigning an authoritative identity.
	 */
	public function editorSymbolCandidates(from:ModuleState, name:String, ?token:CancellationToken,
			?sourceProgram:AstProgram):Array<SemanticSymbolId> {
		var result:Array<SemanticSymbolId> = [],
			seen:Map<String, Bool> = [],
			fromModel = editorModel(from),
			fromProgram = sourceProgram == null ? (fromModel == null ? null : fromModel.program) : sourceProgram,
			fromPackage = fromProgram == null || fromProgram.packageName == null ? null : Std.string(fromProgram.packageName);
		for (state in orderedStates()) {
			if (token != null)
				token.check();
			var model = editorModel(state);
			if (model == null)
				continue;
			var packagePrefix = model.program.packageName == null ? "" : Std.string(model.program.packageName) + ".";
			var visible = state == from || editorModuleVisible(from, state, fromPackage, fromProgram);
			for (symbol in model.index.symbols) {
				if (token != null)
					token.check();
				var separator = symbol.name.lastIndexOf("."),
					shortName = separator < 0 ? symbol.name : symbol.name.substring(separator + 1),
					matches = symbol.name == name
						|| shortName == name
						|| state.name + "." + symbol.name == name
						|| packagePrefix + symbol.name == name;
				// A package/module-qualified spelling is an explicit visibility
				// proof even when the source did not add a separate import. Keep
				// short names subject to the normal package/import rules.
				var qualifiedMatch = state.name + "." + symbol.name == name || packagePrefix + symbol.name == name;
				if (symbol.kind != DeclarationKind.Function && !isTypeKind(symbol.kind) && !qualifiedMatch)
					continue;
				if (!visible && !qualifiedMatch)
					continue;
				if (matches && !seen.exists(Std.string(symbol.id))) {
					seen.set(Std.string(symbol.id), true);
					result.push(symbol.id);
				}
			}
		}
		result.sort(function(left, right) return Reflect.compare(Std.string(left), Std.string(right)));
		return result;
	}

	/** Unique top-level declarations outside the current module's visibility set. */
	public function importableSymbols(from:ModuleState, ?token:CancellationToken):Array<ImportableSymbol> {
		var visible:Map<String, Bool> = [from.name => true],
			byName:Map<String, Array<ImportableSymbol>> = [];
		for (dependency in from.dependencies)
			visible.set(dependency, true);
		for (state in orderedStates()) {
			if (token != null)
				token.check();
			if (visible.exists(state.name))
				continue;
			var model = effectiveModel(state);
			if (model == null)
				continue;
			for (symbol in model.index.symbols)
				if (symbol.name.indexOf(".") < 0 && (isTypeKind(symbol.kind) || symbol.kind == DeclarationKind.Function)) {
					var matches = byName.get(symbol.name);
					if (matches == null)
						byName.set(symbol.name, matches = []);
					matches.push({state: state, symbol: symbol, importPath: state.name});
				}
		}
		var result:Array<ImportableSymbol> = [];
		for (matches in byName)
			if (matches.length == 1)
				result.push(matches[0]);
		result.sort(function(left, right) return Reflect.compare(left.symbol.name, right.symbol.name));
		return result;
	}

	public function enumCases(type:CompilerType, ?token:CancellationToken):Array<IndexedSemanticSymbol> {
		var enumName = switch type {
			case TNullable(element): return enumCases(element, token);
			case TInstance(NominalKind.Enum, name, _): Std.string(name);
			default: return [];
		};
		var result:Array<IndexedSemanticSymbol> = [];
		for (state in orderedStates()) {
			if (token != null)
				token.check();
			var model = effectiveModel(state);
			if (model == null)
				continue;
			var packagePrefix = model.program.packageName == null ? "" : Std.string(model.program.packageName) + ".";
			for (symbol in model.index.symbols)
				if (symbol.kind == DeclarationKind.EnumCase) {
					var separator = symbol.name.lastIndexOf("."),
						owner = separator < 0 ? "" : symbol.name.substring(0, separator);
					if (owner == enumName || packagePrefix + owner == enumName)
						result.push(symbol);
				}
		}
		result.sort(function(left, right) return Reflect.compare(left.name, right.name));
		return result;
	}

	/**
	 * Enumerate members from the editor-visible type snapshots. This deliberately
	 * consumes current recovered declarations when available, while keeping all
	 * type/AST traversal in the semantic workspace instead of the protocol layer.
	 */
	public function editorMembers(type:CompilerType, ?token:CancellationToken):Array<EditorMember> {
		var result:Array<EditorMember> = [],
			seen:Map<String, Bool> = [];
		collectEditorMembers(type, result, seen, token);
		result.sort(function(left, right) return Reflect.compare(left.name, right.name));
		return result;
	}

	/**
	 * Resolve the receiver against the current module's visible type set before
	 * enumerating members. A short nominal name can otherwise match unrelated
	 * packages that happen to declare the same class name.
	 */
	public function editorMembersForContext(from:ModuleState, program:AstProgram, type:CompilerType,
		?token:CancellationToken):Array<EditorMember> {
		var name = editorNominalName(type),
			candidates:Array<SemanticSymbolId> = [];
		if (name != null)
			for (candidate in editorSymbolCandidates(from, name, token, program)) {
				if (token != null)
					token.check();
				var resolved = editorSymbolById(candidate);
				if (resolved != null && isTypeKind(resolved.symbol.kind))
					addUniqueIdentity(candidates, candidate);
			}
		if (candidates.length == 1)
			return editorMembersForIdentity(type, candidates[0], token);
		if (candidates.length > 1)
			return [];
		return editorMembers(type, token);
	}

	/** Resolve one static member through a visible editor type identity. */
	public function editorStaticMemberForContext(from:ModuleState, ownerName:String, memberName:String,
		program:AstProgram, ?token:CancellationToken):Null<EditorMember> {
		for (member in editorStaticMembersForContext(from, ownerName, program, token))
			if (member.name == memberName)
				return member;
		return null;
	}

	/**
	 * Enumerate static members through the unique editor-visible type identity.
	 * This includes inherited class members and keeps short type names scoped to
	 * the current package/import context.
	 */
	public function editorStaticMembersForContext(from:ModuleState, ownerName:String,
		program:AstProgram, ?token:CancellationToken):Array<EditorMember> {
		var identity = editorResolveTypeSymbolId(from, ownerName, program, token),
			result:Array<EditorMember> = [],
			seen:Map<String, Bool> = [],
			visited:Map<String, Bool> = [];
		if (identity == null)
			return result;
		collectEditorStaticMembers(identity, result, seen, visited, token);
		result.sort(function(left, right) return Reflect.compare(left.name, right.name));
		return result;
	}

	function collectEditorStaticMembers(identity:SemanticSymbolId, result:Array<EditorMember>, seen:Map<String, Bool>,
		visited:Map<String, Bool>, ?token:CancellationToken):Void {
		if (token != null)
			token.check();
		var identityKey = Std.string(identity);
		if (visited.exists(identityKey))
			return;
		visited.set(identityKey, true);
		var resolved = editorSymbolById(identity);
		if (resolved == null || !isTypeKind(resolved.symbol.kind))
			return;
		var model = editorModel(resolved.state);
		if (model == null)
			return;
		for (decl in model.program.classes)
			if (sameSpan(decl.span, resolved.symbol.declaration)) {
				var substitutions = editorTypeSubstitutions(decl.typeParameters, []);
				for (field in decl.fields)
					if (field.isStatic)
						addEditorMember(result, seen, field.name, "field", field.name + ":" + editorAstTypeName(field.type, substitutions));
				for (method in decl.methods)
					if (method.isStatic)
						addEditorMember(result, seen, method.name, "method",
							method.name + "(" + [for (argument in method.arguments)
								editorAstTypeName(argument.type, substitutions)].join(",") + "):" + editorAstTypeName(method.result, substitutions));
				if (decl.base != null) {
					var baseName = ModuleCanonicalizer.astTypeName(decl.base),
						baseIdentity = editorResolveTypeSymbolId(resolved.state, baseName, model.program, token);
					if (baseIdentity != null)
						collectEditorStaticMembers(baseIdentity, result, seen, visited, token);
				}
			}
		for (decl in model.program.abstracts)
			if (sameSpan(decl.span, resolved.symbol.declaration)) {
				var substitutions = editorTypeSubstitutions(decl.typeParameters, []);
				for (method in decl.methods)
					if (method.isStatic)
						addEditorMember(result, seen, method.name, "method",
							method.name + "(" + [for (argument in method.arguments)
								editorAstTypeName(argument.type, substitutions)].join(",") + "):" + editorAstTypeName(method.result, substitutions));
			}
		for (decl in model.program.enumAbstracts)
			if (sameSpan(decl.span, resolved.symbol.declaration))
				for (value in decl.values)
					addEditorMember(result, seen, value.name, "field", value.name + ":" + editorAstTypeName(decl.underlying, []));
	}

	function editorMembersForIdentity(type:CompilerType, identity:SemanticSymbolId,
		?token:CancellationToken):Array<EditorMember> {
		if (editorSymbolById(identity) == null)
			return [];
		var result:Array<EditorMember> = [],
			seen:Map<String, Bool> = [];
		collectEditorMembers(type, result, seen, token, identity);
		result.sort(function(left, right) return Reflect.compare(left.name, right.name));
		return result;
	}

	static function editorNominalName(type:CompilerType):Null<String>
		return switch type {
			case TNullable(element): editorNominalName(element);
			case TInstance(_, name, _), TAbstract(name, _, _): name;
			default: null;
		};

	function collectEditorMembers(type:CompilerType, result:Array<EditorMember>, seen:Map<String, Bool>, ?token:CancellationToken,
		?preferredIdentity:SemanticSymbolId):Void {
		if (token != null)
			token.check();
		var key = Std.string(type);
		if (seen.exists(key))
			return;
		seen.set(key, true);
		switch type {
			case TNullable(element):
				collectEditorMembers(element, result, seen, token);
			case TInstance(NominalKind.Class, name, arguments), TInstance(NominalKind.NativeValue, name, arguments):
				for (state in orderedStates()) {
					if (token != null)
						token.check();
					var model = editorModel(state);
					if (model == null)
						continue;
					for (classDecl in model.program.classes)
						if (ownsType(state, model, classDecl.name, name)
							&& (preferredIdentity == null || editorDeclarationIdentity(model, classDecl.span) == preferredIdentity)) {
							var substitutions = editorTypeSubstitutions(classDecl.typeParameters, arguments);
							for (field in classDecl.fields) {
								if (token != null)
									token.check();
								if (!field.isStatic)
									addEditorMember(result, seen, field.name, "field",
										field.name + ":" + editorAstTypeName(field.type, substitutions));
							}
							for (method in classDecl.methods) {
								if (token != null)
									token.check();
								if (!method.isStatic)
									addEditorMember(result, seen, method.name, "method",
										method.name + "(" + [for (argument in method.arguments)
											editorAstTypeName(argument.type, substitutions)].join(",") + "):"
										+ editorAstTypeName(method.result, substitutions));
							}
							if (classDecl.base != null)
								collectEditorMembers(editorTypeFromAst(classDecl.base, substitutions), result, seen, token);
							for (interfaceType in classDecl.interfaces)
								collectEditorMembers(editorTypeFromAst(interfaceType, substitutions), result, seen, token);
						}
				}
			case TInstance(NominalKind.Interface, name, arguments):
				for (state in orderedStates()) {
					if (token != null)
						token.check();
					var model = editorModel(state);
					if (model == null)
						continue;
					for (interfaceDecl in model.program.interfaces)
						if (ownsType(state, model, interfaceDecl.name, name)
							&& (preferredIdentity == null || editorDeclarationIdentity(model, interfaceDecl.span) == preferredIdentity)) {
							var substitutions = editorTypeSubstitutions(interfaceDecl.typeParameters, arguments);
							for (method in interfaceDecl.methods) {
								if (token != null)
									token.check();
								addEditorMember(result, seen, method.name, "method",
									method.name + "(" + [for (argument in method.arguments)
										editorAstTypeName(argument.type, substitutions)].join(",") + "):"
									+ editorAstTypeName(method.result, substitutions));
							}
							for (baseType in interfaceDecl.bases)
								collectEditorMembers(editorTypeFromAst(baseType, substitutions), result, seen, token);
						}
				}
			case TAbstract(name, arguments, _):
				for (state in orderedStates()) {
					if (token != null)
						token.check();
					var model = editorModel(state);
					if (model == null)
						continue;
					for (abstractDecl in model.program.abstracts)
						if (ownsType(state, model, abstractDecl.name, name)
							&& (preferredIdentity == null || editorDeclarationIdentity(model, abstractDecl.span) == preferredIdentity)) {
							var substitutions = editorTypeSubstitutions(abstractDecl.typeParameters, arguments);
							for (method in abstractDecl.methods)
								if (!method.isStatic) {
									if (token != null)
										token.check();
									addEditorMember(result, seen, method.name, "method",
										method.name + "(" + [for (argument in method.arguments)
											editorAstTypeName(argument.type, substitutions)].join(",") + "):"
										+ editorAstTypeName(method.result, substitutions));
								}
						}
				}
			case TArray(_):
				addEditorMember(result, seen, "length", "field", "length:Int");
				addEditorMember(result, seen, "copy", "method", "copy():Array");
				addEditorMember(result, seen, "concat", "method", "concat(other):Array");
				addEditorMember(result, seen, "slice", "method", "slice(start,end):Array");
				addEditorMember(result, seen, "indexOf", "method", "indexOf(value):Int");
				addEditorMember(result, seen, "push", "method", "push(value):Int");
				addEditorMember(result, seen, "pop", "method", "pop():Element");
				addEditorMember(result, seen, "shift", "method", "shift():Element");
			case TMap(_, _):
				addEditorMember(result, seen, "set", "method", "set(key,value):Void");
				addEditorMember(result, seen, "exists", "method", "exists(key):Bool");
				addEditorMember(result, seen, "keys", "method", "keys():Array");
				addEditorMember(result, seen, "values", "method", "values():Array");
				addEditorMember(result, seen, "remove", "method", "remove(key):Bool");
				addEditorMember(result, seen, "clear", "method", "clear():Void");
				addEditorMember(result, seen, "size", "method", "size():Int");
			case TString:
				addEditorMember(result, seen, "length", "field", "length:Int");
				addEditorMember(result, seen, "indexOf", "method", "indexOf(needle):Int");
				addEditorMember(result, seen, "substring", "method", "substring(start,end):String");
			case TAnonymous(_, fields):
				for (field in fields) {
					if (token != null)
						token.check();
					addEditorMember(result, seen, field.name, "field",
						field.name + ":" + editorCompilerTypeName(field.type));
				}
			default:
		}
	}

	static function addEditorMember(result:Array<EditorMember>, seen:Map<String, Bool>, name:String, kind:String, detail:String):Void {
		if (seen.exists("member:" + name))
			return;
		seen.set("member:" + name, true);
		result.push({name: name, kind: kind, detail: detail});
	}

	static function editorTypeSubstitutions(parameters:Array<String>, arguments:Array<CompilerType>):Map<String, String> {
		var result:Map<String, String> = [];
		for (index in 0...parameters.length)
			if (index < arguments.length)
				result.set(parameters[index], editorCompilerTypeName(arguments[index]));
		return result;
	}

	static function editorAstTypeName(type:Null<AstType>, substitutions:Map<String, String>):String {
		if (type == null)
			return "_";
		return switch type {
			case ErrorType(_): "_";
			case IntType: "Int";
			case BoolType: "Bool";
			case FloatType: "Float";
			case StringType: "String";
			case VoidType: "Void";
			case InferredType: "_";
			case NativeAbstractType(declaration, tag): '$declaration<"$tag">';
			case NamedType(name): substitutions.exists(name) ? substitutions.get(name) : name;
			case AppliedType(name, arguments): '$name<${[for (argument in arguments) editorAstTypeName(argument, substitutions)].join(",")}>';
			case ArrayType(element): 'Array<${editorAstTypeName(element, substitutions)}>';
			case MapType(key, value): 'Map<${editorAstTypeName(key, substitutions)},${editorAstTypeName(value, substitutions)}>';
			case NullableType(element): 'Null<${editorAstTypeName(element, substitutions)}>';
			case FunctionType(arguments, result): '(${[for (argument in arguments) editorAstTypeName(argument, substitutions)].join(",")})->${editorAstTypeName(result, substitutions)}';
			case AnonymousType(fields): '{${[for (field in fields) (field.optional ? "?" : "") + field.name + ":" + editorAstTypeName(field.type, substitutions)].join(",")}}';
		};
	}

	static function editorCompilerTypeName(type:CompilerType):String
		return switch type {
			case TInt: "Int";
			case TInt64: "haxe.Int64";
			case TFloat: "Float";
			case TBool: "Bool";
			case TString: "String";
			case TUnknown: "Unknown";
			case TError: "Error";
			case TVoid: "Void";
			case TArray(element): 'Array<${editorCompilerTypeName(element)}>';
			case TIterator(element): 'Iterator<${editorCompilerTypeName(element)}>';
			case TMap(key, value): 'Map<${editorCompilerTypeName(key)},${editorCompilerTypeName(value)}>';
			case TNullable(element): 'Null<${editorCompilerTypeName(element)}>';
			case TFunction(arguments, result): '(${[for (argument in arguments) editorCompilerTypeName(argument)].join(",")})->${editorCompilerTypeName(result)}';
			case TInstance(_, name, arguments): arguments.length == 0 ? name : '$name<${[for (argument in arguments) editorCompilerTypeName(argument)].join(",")}>';
			case TAbstract(name, arguments, _): arguments.length == 0 ? name : '$name<${[for (argument in arguments) editorCompilerTypeName(argument)].join(",")}>';
			case TTypeParameter(_, name): name;
			case TDynamic: "Dynamic";
			case TNativeAbstract(name): name;
			case TNativeScalar(name): name;
			case THlBytes: "hl.Bytes";
			case TBytes: "haxe.io.Bytes";
			case TNever: "Never";
			case TRange: "IntIterator";
			case TNull: "null";
			case TAnonymous(name, _): name;
		};

	function editorTypeFromAst(type:AstType, substitutions:Map<String, String>):CompilerType {
		return switch type {
			case IntType: TInt;
			case BoolType: TBool;
			case FloatType: TFloat;
			case StringType: TString;
			case VoidType: TVoid;
			case NamedType(name): editorTypeFromName(substitutions.exists(name) ? substitutions.get(name) : name);
			case AppliedType(name, arguments): TInstance(editorNominalKind(name), name,
				[for (argument in arguments) editorTypeFromAst(argument, substitutions)]);
			case ArrayType(element): TArray(editorTypeFromAst(element, substitutions));
			case MapType(key, value): TMap(editorTypeFromAst(key, substitutions), editorTypeFromAst(value, substitutions));
			case NullableType(element): TNullable(editorTypeFromAst(element, substitutions));
			default: TUnknown;
		};
	}

	function editorTypeFromName(name:String):CompilerType
		return switch name {
			case "Int": TInt;
			case "Bool": TBool;
			case "Float": TFloat;
			case "String": TString;
			case "Void": TVoid;
			default: TInstance(editorNominalKind(name), name, []);
		};

	function editorNominalKind(name:String):NominalKind {
		for (state in orderedStates()) {
			var model = editorModel(state);
			if (model == null)
				continue;
			for (interfaceDecl in model.program.interfaces)
				if (ownsType(state, model, interfaceDecl.name, name))
					return NominalKind.Interface;
		}
		return NominalKind.Class;
	}

	function memberInner(type:CompilerType, name:String, visiting:Map<String, Bool>):Null<WorkspaceDeclaration> {
		return switch type {
			case TNullable(element): memberInner(element, name, visiting);
			case TInstance(kind, declaration, _):
				switch kind {
					case NominalKind.Class: classMember(declaration, name, visiting);
					case NominalKind.Interface: interfaceMember(declaration, name, visiting);
					case NominalKind.NativeValue: classMember(declaration, name, visiting);
					default: null;
				}
			case TAbstract(declaration, _, _): abstractMember(declaration, name, visiting);
			default: null;
		};
	}

	function classMember(className:String, name:String, visiting:Map<String, Bool>):Null<WorkspaceDeclaration> {
		var visitKey = 'class:$className';
		if (visiting.exists(visitKey))
			return null;
		visiting.set(visitKey, true);
		for (state in orderedStates()) {
			var model = effectiveModel(state);
			if (model == null)
				continue;
			for (decl in model.program.classes)
				if (ownsType(state, model, decl.name, className)) {
					for (field in decl.fields)
						if (field.name == name)
							return {state: state, key: 'class:${decl.name}:field:$name', span: field.span};
					for (method in decl.methods)
						if (method.name == name)
							return {state: state, key: 'class:${decl.name}:method:$name', span: method.span};
					var base = decl.base;
					if (base != null) {
						var inherited = classMember(ModuleCanonicalizer.astTypeName(base), name, visiting);
						if (inherited != null)
							return inherited;
					}
					for (interfaceType in decl.interfaces) {
						var inherited = interfaceMember(ModuleCanonicalizer.astTypeName(interfaceType), name, visiting);
						if (inherited != null)
							return inherited;
					}
				}
		}
		return null;
	}

	function interfaceMember(interfaceName:String, name:String, visiting:Map<String, Bool>):Null<WorkspaceDeclaration> {
		var visitKey = 'interface:$interfaceName';
		if (visiting.exists(visitKey))
			return null;
		visiting.set(visitKey, true);
		for (state in orderedStates()) {
			var model = effectiveModel(state);
			if (model == null)
				continue;
			for (decl in model.program.interfaces)
				if (ownsType(state, model, decl.name, interfaceName)) {
					for (method in decl.methods)
						if (method.name == name)
							return {state: state, key: 'interface:${decl.name}:method:$name', span: method.span};
					for (base in decl.bases) {
						var inherited = interfaceMember(ModuleCanonicalizer.astTypeName(base), name, visiting);
						if (inherited != null)
							return inherited;
					}
				}
		}
		return null;
	}

	function abstractMember(abstractName:String, name:String, visiting:Map<String, Bool>):Null<WorkspaceDeclaration> {
		var visitKey = 'abstract:$abstractName';
		if (visiting.exists(visitKey))
			return null;
		visiting.set(visitKey, true);
		for (state in orderedStates()) {
			var model = effectiveModel(state);
			if (model == null)
				continue;
			for (decl in model.program.abstracts)
				if (ownsType(state, model, decl.name, abstractName))
					for (method in decl.methods)
						if (method.name == name)
							return {state: state, key: 'abstract:${decl.name}:method:$name', span: method.span};
		}
		return null;
	}

	function orderedStates():Array<ModuleState> {
		var names = [for (name in modules.keys()) name];
		names.sort(Reflect.compare);
		return [for (name in names) modules.get(name)];
	}

	function declarationsIn(state:ModuleState, name:String):Array<WorkspaceDeclaration> {
		var result:Array<WorkspaceDeclaration> = [],
			model = effectiveModel(state);
		if (model != null) {
			var kinds:Array<DeclarationKind> = [
				DeclarationKind.Alias,
				DeclarationKind.Function,
				DeclarationKind.Class,
				DeclarationKind.Interface,
				DeclarationKind.Enum,
				DeclarationKind.Abstract
			];
			for (kind in kinds) {
				var declaration = model.declarations.symbol(kind, name);
				if (declaration != null)
					result.push({state: state, key: declaration.id, span: declaration.span});
			}
		}
		return result;
	}

	static function contains(declarations:Array<WorkspaceDeclaration>, candidate:WorkspaceDeclaration):Bool {
		for (declaration in declarations)
			if (declaration.state == candidate.state && declaration.key == candidate.key)
				return true;
		return false;
	}

	static function ownsType(state:ModuleState, model:compiler.semantic.SemanticModel, declaredName:String, requestedName:String):Bool {
		if (requestedName == declaredName || requestedName == state.name)
			return true;
		var packageName = model.program.packageName;
		return packageName != null && requestedName == packageName + "." + declaredName;
	}

	static function effectiveModel(state:ModuleState):Null<compiler.semantic.SemanticModel> {
		var exact = EditorWorkspaceView.currentExact(state);
		if (exact != null)
			return exact.semanticModel;
		// During strict analysis the mutable candidate model is intentionally
		// unpublished until all builder passes finish. Compiler resolution still
		// needs to see that in-flight model; editor queries never reach this path
		// after update because update clears the raw exact fields and publishes a
		// current recovered snapshot.
		if (state.ast != null && state.semanticModel != null
			&& state.semanticModel.revision == state.revision
			&& state.semanticModel.source == state.source)
			return state.semanticModel;
		return state.lastGood == null ? null : state.lastGood.semanticModel;
	}

	static function editorModel(state:ModuleState):Null<compiler.semantic.SemanticModel>
		return EditorWorkspaceView.semanticModel(state);

	static function editorSymbolAt(model:Null<compiler.semantic.SemanticModel>, span:SourceSpan):Null<IndexedSemanticSymbol> {
		if (model == null)
			return null;
		for (symbol in model.index.symbols)
			if (sameSpan(symbol.declaration, span) && isTypeKind(symbol.kind))
				return symbol;
		return null;
	}

	static function editorDeclarationIdentity(model:compiler.semantic.SemanticModel, span:SourceSpan):Null<SemanticSymbolId> {
		for (symbol in model.index.symbols)
			if (sameSpan(symbol.declaration, span) && isTypeKind(symbol.kind))
				return symbol.id;
		return null;
	}
}
