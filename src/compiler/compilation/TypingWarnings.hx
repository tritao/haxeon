package compiler.compilation;

import compiler.Diagnostic;
import compiler.modules.ModuleState;
import compiler.semantic.ModuleCanonicalizer;
import compiler.types.TypedAst.TypedFunction;
import compiler.types.TypedAst.TypedProgram;

/**
	Keeps the typer's warnings across incremental compiles. A compile types only what changed, so each module remembers its
	warnings by the source function or field initializer that raised them: what was typed again replaces its entry, what was
	reused keeps it, and what was deleted drops it. Every module's diagnostics then hold its errors and all its warnings.
**/
class TypingWarnings {
	public static function publish(context:CompilationContext, entryModule:String, names:Array<String>, typed:TypedProgram,
			rollbackModules:Map<String, ModuleState>):Void {
		var moduleByPath:Map<String, String> = [];
		for (name in names) {
			var state = context.modules.get(name);
			if (state != null)
				moduleByPath.set(state.source.path, name);
		}
		// What this compile typed, by source owner: a lambda or specialization adds to the function it was written in or made from.
		var typedNow:Map<String, Map<String, Array<Diagnostic>>> = [];
		function record(module:Null<String>, key:String, warnings:Null<Array<Diagnostic>>):Void {
			if (module == null)
				return;
			var byKey = typedNow.get(module);
			if (byKey == null)
				typedNow.set(module, byKey = []);
			var entry = byKey.get(key);
			if (entry == null)
				byKey.set(key, entry = []);
			if (warnings != null)
				for (warning in warnings)
					entry.push(warning);
		}
		for (fn in typed.functions)
			record(moduleByPath.get(fn.span.file.path), ownerKey(fn), fn.warnings);
		for (classDecl in typed.classes)
			for (field in classDecl.fields)
				if (field.initializer != null)
					record(moduleByPath.get(field.span.file.path), classDecl.name + ".__init." + field.name, field.warnings);
		for (name in names) {
			var state = context.modules.get(name);
			if (state == null)
				continue;
			var stored = state.typingWarnings, byKey = typedNow.get(name), next:Map<String, Array<Diagnostic>> = [],
				declared = declarations(state, entryModule), pruned = false;
			for (key => warnings in stored)
				if (declared.exists(declarationOf(key)))
					next.set(key, warnings);
				else
					pruned = true;
			if (byKey != null)
				for (key => warnings in byKey)
					next.set(key, warnings);
			var warnings = unique(next),
				errors = [for (diagnostic in state.diagnostics) if (!isWarning(diagnostic)) diagnostic];
			// Nothing typed again or deleted, and the diagnostics already list these warnings: leave the module as it is.
			if (byKey == null
				&& !pruned
				&& sameWarnings([for (diagnostic in state.diagnostics) if (isWarning(diagnostic)) diagnostic], warnings))
				continue;
			state = context.writableState(name, rollbackModules);
			state.typingWarnings = next;
			state.diagnostics = errors.concat(warnings);
		}
	}

	/** The source function a typed function belongs to: its own name, or the function it was written in or specialized from. */
	static function ownerKey(fn:TypedFunction):String
		return fn.origin == null ? fn.name : fn.origin;

	/** The declaration a key names: the function itself, or the class of a field initializer. */
	static function declarationOf(key:String):String {
		var initializer = key.indexOf(".__init.");
		return initializer >= 0 ? key.substr(0, initializer) : key;
	}

	/** The canonical names of the functions, methods and classes the module declares now. */
	static function declarations(state:ModuleState, entryModule:String):Map<String, Bool> {
		var declared:Map<String, Bool> = [];
		for (local in state.signatureFingerprints.keys())
			declared.set(ModuleCanonicalizer.canonicalName(state.name, entryModule, local), true);
		for (className in state.wireFieldFingerprints.keys())
			declared.set(className, true);
		return declared;
	}

	/** One warning per code and place (a generic body typed for several type arguments warns once), in source order. */
	static function unique(byKey:Map<String, Array<Diagnostic>>):Array<Diagnostic> {
		var seen:Map<String, Bool> = [], result:Array<Diagnostic> = [];
		for (warnings in byKey)
			for (warning in warnings) {
				var identity = '${warning.code}@${warning.span.file.path}:${warning.span.start}:${warning.span.end}';
				if (seen.exists(identity))
					continue;
				seen.set(identity, true);
				result.push(warning);
			}
		result.sort((left, right) -> left.span.start - right.span.start);
		return result;
	}

	static function isWarning(diagnostic:Diagnostic):Bool
		return diagnostic.severity.match(Warning);

	static function sameWarnings(left:Array<Diagnostic>, right:Array<Diagnostic>):Bool {
		if (left.length != right.length)
			return false;
		for (index in 0...left.length)
			if (left[index] != right[index])
				return false;
		return true;
	}
}
