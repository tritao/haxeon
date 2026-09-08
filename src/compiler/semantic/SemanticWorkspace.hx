package compiler.semantic;

import compiler.Source.SourceSpan;
import compiler.modules.ModuleState;
import compiler.types.DeclarationIndex.DeclarationKind;
import compiler.types.Type.CompilerType;
import compiler.types.Type.NominalKind;
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

	public function resolveSymbolId(name:String):Null<SemanticSymbolId> {
		ensureResolutionIndexes();
		return symbolResolutionIndex.get(name);
	}

	public function resolveTypeSymbolId(name:String):Null<SemanticSymbolId> {
		ensureResolutionIndexes();
		return typeResolutionIndex.get(name);
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

	public function indexedSignature(id:SemanticSymbolId):Null<SemanticSignatureInfo> {
		for (state in orderedStates()) {
			var model = effectiveModel(state),
				signature = model == null ? null : model.index.signature(id);
			if (signature != null)
				return signature;
		}
		return null;
	}

	public function indexedLocations(id:SemanticSymbolId, ?token:CancellationToken):Array<{state:ModuleState, span:SourceSpan}> {
		var result = [];
		for (state in orderedStates()) {
			if (token != null)
				token.check();
			var model = effectiveModel(state);
			if (model != null)
				for (span in model.index.locations(id))
					result.push({state: state, span: span});
		}
		return result;
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
		for (existing in result)
			if (existing == identity)
				return;
		result.push(identity);
	}

	public function implementations(id:SemanticSymbolId, ?token:CancellationToken):Array<WorkspaceDeclaration> {
		var resolved = indexedSymbol(id);
		if (resolved == null)
			return [];
		var owner:Null<String> = null,
			member:Null<String> = null,
			targetIsType = false;
		for (state in orderedStates()) {
			var model = effectiveModel(state);
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
			var model = effectiveModel(state);
			if (model == null)
				continue;
			for (decl in model.program.classes) {
				var identity = qualifiedType(model, decl.name);
				if (identity == owner || !inheritsFrom(identity, owner, []))
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
				for (symbol in model.index.symbols)
					if (!seen.exists(symbol.id)) {
						seen.set(symbol.id, true);
						result.push(symbol);
					}
		}
		result.sort(function(left, right) return Reflect.compare(left.name, right.name));
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

	function memberInner(type:CompilerType, name:String, visiting:Map<String, Bool>):Null<WorkspaceDeclaration> {
		return switch type {
			case TNullable(element): memberInner(element, name, visiting);
			case TInstance(kind, declaration, _):
				switch kind {
					case NominalKind.Class: classMember(declaration, name, visiting);
					case NominalKind.Interface: interfaceMember(declaration, name, visiting);
					default: null;
				}
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

	static function effectiveModel(state:ModuleState):Null<compiler.semantic.SemanticModel>
		return state.ast != null ? state.semanticModel : state.recoveredSemanticModel != null ? state.recoveredSemanticModel : state.lastGoodSemanticModel;
}
