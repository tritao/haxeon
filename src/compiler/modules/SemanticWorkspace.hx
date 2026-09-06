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

/** Shared cross-module name and member resolution over current or last-good models. */
class SemanticWorkspace {
	final modules:Map<String, ModuleState>;

	public function new(modules:Map<String, ModuleState>)
		this.modules = modules;

	public function global(from:ModuleState, name:String):Null<WorkspaceDeclaration> {
		var visible = [from];
		for (dependency in from.dependencies) {
			var state = modules.get(dependency);
			if (state != null)
				visible.push(state);
		}
		for (state in visible) {
			var model = effectiveModel(state);
			if (model == null)
				continue;
			for (kind in [Alias, Function, Class, Interface, Enum, Abstract]) {
				var declaration = model.declarations.symbol(kind, name);
				if (declaration != null)
					return {state: state, key: declaration.id, span: declaration.span};
			}
		}
		return null;
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
					if (decl.base != null) {
						var inherited = classMember(decl.base, name, visiting);
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

	static function ownsType(state:ModuleState, model:compiler.types.SemanticModel, declaredName:String, requestedName:String):Bool {
		if (requestedName == declaredName || requestedName == state.name)
			return true;
		var packageName = model.program.packageName;
		return packageName != null && requestedName == packageName + "." + declaredName;
	}

	static function effectiveModel(state:ModuleState):Null<compiler.types.SemanticModel>
		return state.ast == null ? state.lastGoodSemanticModel : state.semanticModel;
}
