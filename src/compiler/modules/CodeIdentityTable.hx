package compiler.modules;

import compiler.Source.SourceFile;
import compiler.compilation.CompilationContext;
import haxe.crypto.Sha256;
import sys.FileSystem;
import sys.io.File;

/**
 * Code identities for the program being compiled, published to the running program through the stdlib module
 * `haxeon.build.CodeIdentityTable`.
 *
 * The identity of a module is a hash of its own source, the identities of the modules it imports (so, transitively, of its
 * whole dependency closure) and the compiler salt. Import cycles are condensed first: every module of a cycle shares one
 * identity, made from all their sources. It is a function of sources alone, so clean and incremental builds agree.
 *
 * The table is one generated literal in one module, rewritten on every compile whose identities changed. That module is
 * the only thing the incremental compiler sees change; nothing that merely reads an identity needs retyping.
 */
class CodeIdentityTable {
	public static inline final MODULE = "haxeon.build.CodeIdentityTable";
	static inline final BEGIN = "/*IDENTITY-BEGIN*/";
	static inline final END = "/*IDENTITY-END*/";

	/** Refreshes the generated table if the program reaches it (a program that never reads identities pays nothing). */
	public static function refresh(context:CompilationContext, names:Array<String>, rollback:Map<String, ModuleState>, entry:String,
			body:Map<String, Bool>, signatures:Map<String, Bool>, structural:Map<String, Bool>):Void {
		if (names.indexOf(MODULE) < 0)
			return;
		var modules = context.modules;
		var state = modules.get(MODULE);
		if (state == null)
			return;
		var salt = context.identitySalt();
		var computed = identities(modules, names, salt);
		dumpGraph(modules, names, computed);
		var text = render(state.source.text, computed);
		if (text == state.source.text)
			return;
		state = context.writableState(MODULE, rollback);
		state.render(new SourceFile(state.source.path, text));
		context.parse(state, entry, body, signatures, structural);
		context.addTypeDependencies(state);
	}

	/**
	 * Diagnostics for `haxeon identity-path`: when `HAXEON_IDENTITY_GRAPH` names a file, the import graph the identities were made
	 * from is written there, one module per line: `name`, a tab, then its imports separated by commas.
	 */
	static function dumpGraph(modules:Map<String, ModuleState>, names:Array<String>, computed:Map<String, String>):Void {
		var path = Sys.getEnv("HAXEON_IDENTITY_GRAPH");
		if (path == null || path == "")
			return;
		var lines = [];
		var members = [for (name in computed.keys()) name];
		members.sort(Reflect.compare);
		for (name in members) {
			var state = modules.get(name);
			var imports = [for (dependency in state.dependencies) if (computed.exists(dependency)) dependency];
			imports.sort(Reflect.compare);
			lines.push(name + "\t" + imports.join(","));
		}
		File.saveContent(path, lines.join("\n") + "\n");
	}

	/** `template` with the text between the markers replaced by the table literal. */
	public static function render(template:String, identities:Map<String, String>):String {
		var begin = template.indexOf(BEGIN), end = template.indexOf(END);
		if (begin < 0 || end < begin)
			throw 'Module "$MODULE" has no identity markers';
		var names = [for (name in identities.keys()) name];
		names.sort(Reflect.compare);
		var lines = new StringBuf();
		for (name in names) {
			lines.add(name);
			lines.add("\\t");
			lines.add(identities.get(name));
			lines.add("\\n");
		}
		return template.substring(0, begin + BEGIN.length) + '"' + lines.toString() + '"' + template.substring(end);
	}

	/** The identity of each module in `names` (the generated table module itself excluded, and edges to it ignored). */
	public static function identities(modules:Map<String, ModuleState>, names:Array<String>, salt:String):Map<String, String> {
		var known:Map<String, Bool> = [], edges:Map<String, Array<String>> = [];
		var members = [for (name in names) if (name != MODULE && modules.exists(name)) name];
		members.sort(Reflect.compare);
		for (name in members)
			known.set(name, true);
		for (name in members) {
			var targets = [];
			for (dependency in modules.get(name).dependencies)
				if (known.exists(dependency) && targets.indexOf(dependency) < 0)
					targets.push(dependency);
			targets.sort(Reflect.compare);
			edges.set(name, targets);
		}
		// Tarjan's strongly connected components, iteratively (a module graph can be thousands deep). A component completes
		// after every component it depends on, so its identity can be made the moment it completes.
		var index:Map<String, Int> = [], low:Map<String, Int> = [], onStack:Map<String, Bool> = [], stack:Array<String> = [];
		var componentOf:Map<String, String> = [], result:Map<String, String> = [];
		var counter = 0;
		for (root in members) {
			if (index.exists(root))
				continue;
			var frames = [root], cursors = [0];
			index.set(root, counter);
			low.set(root, counter);
			counter++;
			stack.push(root);
			onStack.set(root, true);
			while (frames.length > 0) {
				var top = frames.length - 1, current = frames[top], targets = edges.get(current);
				if (cursors[top] < targets.length) {
					var next = targets[cursors[top]++];
					if (!index.exists(next)) {
						index.set(next, counter);
						low.set(next, counter);
						counter++;
						stack.push(next);
						onStack.set(next, true);
						frames.push(next);
						cursors.push(0);
					} else if (onStack.exists(next))
						low.set(current, Std.int(Math.min(low.get(current), index.get(next))));
				} else {
					if (low.get(current) == index.get(current)) {
						var component = [];
						while (true) {
							var member = stack.pop();
							onStack.remove(member);
							component.push(member);
							if (member == current)
								break;
						}
						component.sort(Reflect.compare);
						var identity = componentIdentity(modules, edges, component, componentOf, salt);
						for (member in component) {
							componentOf.set(member, identity);
							result.set(member, identity);
						}
					}
					frames.pop();
					cursors.pop();
					if (frames.length > 0) {
						var parent = frames[frames.length - 1];
						low.set(parent, Std.int(Math.min(low.get(parent), low.get(current))));
					}
				}
			}
		}
		return result;
	}

	static function componentIdentity(modules:Map<String, ModuleState>, edges:Map<String, Array<String>>, component:Array<String>,
			done:Map<String, String>, salt:String):String {
		var inside:Map<String, Bool> = [];
		for (member in component)
			inside.set(member, true);
		var text = new StringBuf(), outside:Map<String, Bool> = [];
		text.add(salt);
		for (member in component) {
			text.add("\nmodule " + member + " " + modules.get(member).source.strongHash());
			for (target in edges.get(member))
				if (!inside.exists(target))
					outside.set(done.get(target), true);
		}
		var dependencies = [for (identity in outside.keys()) identity];
		dependencies.sort(Reflect.compare);
		for (identity in dependencies)
			text.add("\nneeds " + identity);
		return Sha256.encode(text.toString()).substr(0, 32);
	}

	static var cachedVersion:Null<String>;

	/**
	 * A fingerprint of the running compiler: its source tree when it runs from source (`haxe --run`), or its program file.
	 * Computed once per process.
	 */
	public static function compilerVersion():String {
		var known = cachedVersion;
		if (known != null)
			return known;
		var program = Sys.programPath(), hashes = [];
		try {
			if (StringTools.endsWith(program, ".hx")) {
				var root = haxe.io.Path.directory(program);
				while (root.length > 1 && haxe.io.Path.withoutDirectory(root) != "compiler")
					root = haxe.io.Path.directory(root);
				hashTree(root, hashes);
			} else
				hashes.push(SourceFile.hashBytes(File.getBytes(program)));
		} catch (error:Dynamic) {
			hashes.push("unreadable:" + program);
		}
		known = Sha256.encode(hashes.join("\n")).substr(0, 32);
		cachedVersion = known;
		return known;
	}

	static function hashTree(directory:String, into:Array<String>):Void {
		var entries = FileSystem.readDirectory(directory);
		entries.sort(Reflect.compare);
		for (entry in entries) {
			var path = directory + "/" + entry;
			if (FileSystem.isDirectory(path))
				hashTree(path, into);
			else if (StringTools.endsWith(entry, ".hx"))
				into.push(entry + " " + SourceFile.hashBytes(File.getBytes(path)));
		}
	}
}
