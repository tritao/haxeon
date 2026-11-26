package compiler.types.typing;

import compiler.core.InternalError;
import compiler.core.Source.SourceFile;
import compiler.semantic.SemanticProgram;
import compiler.syntax.Ast.AstAbstract;
import compiler.syntax.Ast.AstClass;
import compiler.syntax.Ast.AstEnum;
import compiler.syntax.Ast.AstFunction;
import compiler.syntax.Ast.AstInterface;
import compiler.syntax.AstFunctions;
import haxe.ds.ObjectMap;

/** A function's declaration key, and the same key when its signature is left, in part, to its body; else null. */
class DeclarationKey {
	public final key:Null<String>;
	public final inferred:Null<String>;

	public function new(key:Null<String>, inferred:Null<String>) {
		this.key = key;
		this.inferred = inferred;
	}
}

/**
 * The declaration keys of one module's canonical declarations (`ModuleState.canonicalClasses` and the rest): which of their
 * functions leave their signature, in part, to their bodies, by declaration order; a function's key is its owner's name and its
 * own, made when a build first looks it up (`find`). Made once per canonicalization of the module and kept in the session's
 * database (`SessionState.declarationKeys`): a module whose canonical declarations are the ones it was made from keeps it, so a
 * build pays only for the modules canonicalized again.
 */
class ModuleDeclarationKeys {
	/** The file the declarations' spans name: a function is looked up in the keys of its span's file (`DeclarationKeys`). */
	public final file:Null<SourceFile>;

	/** The functions of the declarations whose span names another file, with their keys. */
	public final elsewhere:Array<{fn:AstFunction, key:DeclarationKey}> = [];

	/** By declaration order (`walk`), whether the function leaves its signature, in part, to its body. */
	final inferred:Array<Bool> = [];

	final classes:Array<AstClass>;
	final abstracts:Array<AstAbstract>;
	final enums:Array<AstEnum>;
	final interfaces:Array<AstInterface>;
	final functions:Array<AstFunction>;

	public function new(classes:Array<AstClass>, abstracts:Array<AstAbstract>, enums:Array<AstEnum>,
			interfaces:Array<AstInterface>, functions:Array<AstFunction>) {
		this.classes = classes;
		this.abstracts = abstracts;
		this.enums = enums;
		this.interfaces = interfaces;
		this.functions = functions;
		var file = firstFile(classes, abstracts, enums, interfaces, functions);
		this.file = file;
		walk((fn, owner, inferable, index) -> {
			var leaves = inferable && AstFunctions.leavesSignatureToInference(fn);
			inferred.push(leaves);
			if (fn.span.file != file)
				elsewhere.push({fn: fn, key: keyOf(fn, owner, leaves)});
			return false;
		});
	}

	/** The key of `fn`, one of the functions of the module's declarations, or null for another function. */
	public function find(fn:AstFunction):Null<DeclarationKey> {
		var found:Null<DeclarationKey> = null;
		walk((candidate, owner, _, index) -> {
			if (candidate != fn)
				return false;
			found = keyOf(fn, owner, inferred[index]);
			return true;
		});
		return found;
	}

	/**
	 * Calls `visit` with each function of the declarations, its owner's name (null for a module function), whether its body can
	 * give its signature (an interface's or enum's method cannot) and its place in that order, until `visit` returns true.
	 */
	function walk(visit:(fn:AstFunction, owner:Null<String>, inferable:Bool, index:Int) -> Bool):Void {
		var index = 0;
		for (decl in classes)
			for (method in decl.methods)
				if (visit(method, decl.name, true, index++))
					return;
		for (decl in abstracts)
			for (method in decl.methods)
				if (visit(method, decl.name, true, index++))
					return;
		for (decl in enums)
			if (decl.methods != null)
				for (method in decl.methods)
					if (visit(method, decl.name, false, index++))
						return;
		// An interface's method has no body to give its signature.
		for (decl in interfaces)
			for (method in decl.methods)
				if (visit(method, decl.name, false, index++))
					return;
		for (fn in functions)
			if (visit(fn, null, true, index++))
				return;
	}

	static function keyOf(fn:AstFunction, owner:Null<String>, inferred:Bool):DeclarationKey {
		var key = owner == null ? fn.name : owner + "." + fn.name;
		return new DeclarationKey(key, inferred ? key : null);
	}

	/** Whether this was made from these canonical declarations: a module canonicalized again holds new ones. */
	public function madeFrom(classes:Array<AstClass>, abstracts:Array<AstAbstract>, enums:Array<AstEnum>,
			interfaces:Array<AstInterface>, functions:Array<AstFunction>):Bool
		return this.classes == classes && this.abstracts == abstracts && this.enums == enums
			&& this.interfaces == interfaces && this.functions == functions;

	/**
	 * Whether these are the methods of one of the module's classes as it was canonicalized, whose keys this holds: a class the
	 * semantic program refreshed or gave an implicit constructor is another object, which keeps the methods it did not change in the
	 * same array.
	 */
	public function holdsClassMethods(methods:Array<AstFunction>):Bool {
		for (decl in classes)
			if (decl.methods == methods)
				return true;
		return false;
	}

	public function holdsAbstractMethods(methods:Array<AstFunction>):Bool {
		for (decl in abstracts)
			if (decl.methods == methods)
				return true;
		return false;
	}

	public function holdsEnumMethods(methods:Array<AstFunction>):Bool {
		for (decl in enums)
			if (decl.methods == methods)
				return true;
		return false;
	}

	public function holdsInterfaceMethods(methods:Array<AstFunction>):Bool {
		for (decl in interfaces)
			if (decl.methods == methods)
				return true;
		return false;
	}

	static function firstFile(classes:Array<AstClass>, abstracts:Array<AstAbstract>, enums:Array<AstEnum>,
			interfaces:Array<AstInterface>, functions:Array<AstFunction>):Null<SourceFile> {
		for (decl in classes)
			return decl.span.file;
		for (decl in abstracts)
			return decl.span.file;
		for (decl in enums)
			return decl.span.file;
		for (decl in interfaces)
			return decl.span.file;
		for (fn in functions)
			return fn.span.file;
		return null;
	}
}

/**
 * The key of each function of a program, for `DeclarationTypeTable`: the keys of the modules' canonical declarations
 * (`ModuleDeclarationKeys`), each found through the file the function's span names, and the keys of the functions the semantic
 * program made itself (an abstract's methods with its type parameters, an implicit constructor, an interface variable's accessors,
 * a function given its new body), found by a walk of the program's declarations that skips every one a module holds.
 */
class DeclarationKeys {
	final modules = new ObjectMap<SourceFile, ModuleDeclarationKeys>();

	/**
	 * The key of each function looked up so far, `none` for one without; and of the functions no module's keys hold: those the
	 * semantic program made, and the copies the typer aliases (`alias`).
	 */
	final resolved = new ObjectMap<AstFunction, DeclarationKey>();

	final none = new DeclarationKey(null, null);

	public function new(semantic:SemanticProgram, moduleKeys:Array<ModuleDeclarationKeys>) {
		for (module in moduleKeys) {
			var file = module.file;
			if (file != null)
				modules.set(file, module);
			for (entry in module.elsewhere)
				resolved.set(entry.fn, entry.key);
		}
		var program = semantic.program;
		for (decl in program.classes) {
			var module = modules.get(decl.span.file);
			if (module == null || !module.holdsClassMethods(decl.methods))
				for (method in decl.methods)
					addMissing(method, decl.name + "." + method.name, true);
		}
		for (decl in program.abstracts) {
			var module = modules.get(decl.span.file),
				heldHere = module != null && module.holdsAbstractMethods(decl.methods);
			for (method in decl.methods) {
				var name = decl.name + "." + method.name;
				if (!heldHere)
					addMissing(method, name, true);
				// The signature table holds an abstract's methods with the owner's type parameters added.
				var signature = semantic.signatures.get(name);
				if (signature != null && signature != method)
					addMissing(signature, name, true);
			}
		}
		for (decl in program.enums) {
			var module = modules.get(decl.span.file);
			if (decl.methods != null && (module == null || !module.holdsEnumMethods(decl.methods)))
				for (method in decl.methods)
					addMissing(method, decl.name + "." + method.name, false);
		}
		for (decl in program.interfaces) {
			var module = modules.get(decl.span.file);
			if (module == null || !module.holdsInterfaceMethods(decl.methods))
				for (method in decl.methods)
					addMissing(method, decl.name + "." + method.name, false);
		}
		for (fn in program.functions)
			addMissing(fn, fn.name, true);
	}

	/** The key of the declaration `fn` is, or null for a function no declaration holds (a closure, a specialization). */
	public inline function key(fn:AstFunction):Null<String>
		return resolve(fn).key;

	/** The key of `fn` when its signature is left, in part, to its body; null otherwise. */
	public inline function inferredKey(fn:AstFunction):Null<String>
		return resolve(fn).inferred;

	/** Gives `copy`, a function rewritten from `original` with the same arguments and result, the original's keys. */
	public function alias(copy:AstFunction, original:AstFunction):Void {
		var found = resolve(original);
		if (found.key != null)
			resolved.set(copy, found);
	}

	/** The keys of `fn`, found in the module its span's file is the first time it is looked up. */
	function resolve(fn:AstFunction):DeclarationKey {
		var known = resolved.get(fn);
		if (known != null)
			return known;
		var module = modules.get(fn.span.file), found = module == null ? null : module.find(fn);
		known = found == null ? none : found;
		resolved.set(fn, known);
		return known;
	}

	/**
	 * `--check-reuse`: fails unless every function of `semantic` has the keys that keys made afresh from the whole program give it,
	 * walking every declaration and signature.
	 */
	public function check(semantic:SemanticProgram):Void {
		var fresh = new ObjectMap<AstFunction, String>(),
			freshInferred = new ObjectMap<AstFunction, String>(),
			functions:Array<AstFunction> = [];
		function mark(fn:AstFunction, name:String):Void
			if (AstFunctions.leavesSignatureToInference(fn))
				freshInferred.set(fn, name);
		for (name => fn in semantic.signatures) {
			fresh.set(fn, name);
			functions.push(fn);
		}
		for (decl in semantic.program.abstracts)
			for (method in decl.methods) {
				fresh.set(method, decl.name + "." + method.name);
				functions.push(method);
			}
		for (decl in semantic.program.enums)
			if (decl.methods != null)
				for (method in decl.methods) {
					fresh.set(method, decl.name + "." + method.name);
					functions.push(method);
				}
		for (decl in semantic.program.classes)
			for (method in decl.methods) {
				if (!fresh.exists(method))
					fresh.set(method, decl.name + "." + method.name);
				functions.push(method);
			}
		var interfaces = [for (decl in semantic.program.interfaces) decl.name => true];
		for (name => fn in semantic.signatures) {
			var info = semantic.methodInfo.get(name);
			if (info == null || !interfaces.exists(info.owner))
				mark(fn, name);
		}
		for (fn in semantic.program.functions)
			mark(fn, fn.name);
		for (decl in semantic.program.classes)
			for (method in decl.methods)
				mark(method, decl.name + "." + method.name);
		for (decl in semantic.program.abstracts)
			for (method in decl.methods)
				mark(method, decl.name + "." + method.name);
		for (fn in functions)
			if (key(fn) != fresh.get(fn) || inferredKey(fn) != freshInferred.get(fn))
				throw new InternalError('--check-reuse: the kept declaration keys of "${fresh.get(fn)}" are "${key(fn)}" and "${inferredKey(fn)}", made from the whole program "${fresh.get(fn)}" and "${freshInferred.get(fn)}"');
	}

	function addMissing(fn:AstFunction, name:String, inferable:Bool):Void
		if (key(fn) == null)
			resolved.set(fn,
				new DeclarationKey(name, inferable && AstFunctions.leavesSignatureToInference(fn) ? name : null));
}
