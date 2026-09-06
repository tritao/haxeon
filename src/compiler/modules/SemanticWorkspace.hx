package compiler.modules;

import compiler.Source.SourceSpan;
import compiler.types.DeclarationIndex.DeclarationKind;
import compiler.types.Type.CompilerType;

/** A declaration resolved against the effective snapshots of a module workspace. */
typedef WorkspaceDeclaration = {
	final state:ModuleState;
	final key:String;
	final span:SourceSpan;
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

	function memberInner(type:CompilerType, name:String, visiting:Map<String, Bool>):Null<WorkspaceDeclaration> {
		return switch type {
			case TNullable(element): memberInner(element, name, visiting);
			case TClass(className): classMember(className, name, visiting);
			case TInterface(interfaceName): interfaceMember(interfaceName, name, visiting);
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
						var inherited = classMember(base, name, visiting);
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
						var inherited = interfaceMember(base, name, visiting);
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

	static function ownsType(state:ModuleState, model:compiler.types.SemanticModel, declaredName:String, requestedName:String):Bool {
		if (requestedName == declaredName || requestedName == state.name)
			return true;
		var packageName = model.program.packageName;
		return packageName != null && requestedName == packageName + "." + declaredName;
	}

	static function effectiveModel(state:ModuleState):Null<compiler.types.SemanticModel>
		return state.ast == null ? state.lastGoodSemanticModel : state.semanticModel;
}
