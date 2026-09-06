package compiler.modules;

import compiler.Diagnostic;
import compiler.Diagnostic.CompileError;
import compiler.service.CancellationToken;

/** Incrementally discovers and validates the source-module closure rooted at an entry module. */
class ModuleReachability {
	final modules:Map<String, ModuleState>;
	final pending:Array<String>;
	final seen:Map<String, Bool> = [];
	var cursor = 0;
	var current:ModuleState;

	public function new(modules:Map<String, ModuleState>, entryModule:String) {
		if (!modules.exists(entryModule))
			throw 'Missing entry module "$entryModule"';
		this.modules = modules;
		pending = [entryModule];
	}

	public function hasNext(?token:CancellationToken):Bool {
		while (cursor < pending.length) {
			if (token != null)
				token.check();
			var name = pending[cursor++];
			if (seen.exists(name))
				continue;
			seen.set(name, true);
			if (modules.exists(name)) {
				current = modules.get(name);
				return true;
			}
		}
		return false;
	}

	public function next():ModuleState
		return current;

	public function includeDependencies(state:ModuleState):Void
		for (dependency in state.dependencies)
			if (!seen.exists(dependency))
				pending.push(dependency);

	public function finish(?token:CancellationToken):Array<String> {
		var names = [for (name in seen.keys()) if (modules.exists(name)) name];
		names.sort(Reflect.compare);
		for (name in names) {
			if (token != null)
				token.check();
			for (dependency in modules.get(name).dependencies)
				if (!modules.exists(dependency)) {
					var state = modules.get(name),
						span = state.source.span(0, state.source.text.length);
					var diagnostic = new Diagnostic("E2001", 'Missing module "$dependency"', span);
					state.diagnostics.push(diagnostic);
					throw new CompileError(diagnostic);
				}
		}
		return names;
	}
}
