package compiler.compilation;

import compiler.core.Source.SourceFile;
import compiler.query.Digest;
import compiler.query.QueryDatabase;
import compiler.query.QueryKind;

/**
 * What a session's builds are made from, as inputs of its query database (`docs/design/QUERY_ENGINE.md`, Model): each module's
 * source, the embedded texts its parse read, the compile options that change output, the target profile, and the rest of the
 * configuration a build reads (defines, source roots, exported functions, FFI interfaces). An input set to an equal value starts
 * no revision, so the database's input revision is what a result reused whole is current with (`Compiler.compile`).
 */
class BuildInputs {
	public final database:QueryDatabase;

	/** By module id: the module's source file (path, physical path, standard-library flag and text). */
	public final sources:QueryKind<SourceFile>;

	/** By module id: the digests of the embedded texts the module's parse read, as their files hold them now. */
	public final embedded:QueryKind<String>;

	/** The compile options that change output (`CompileOptions.key`). */
	public final options:QueryKind<String>;

	/** The target profile the IR is made for (`TargetProfile.key`). */
	public final target:QueryKind<compiler.ir.pipeline.TargetProfile>;

	/** The defines and their scope, as the request names them (`Compiler.configure`). */
	public final configuration:QueryKind<String>;

	/** The source roots modules are loaded from, in the order they were added. */
	public final sourceRoots:QueryKind<String>;

	/** The functions the host calls, sorted. */
	public final exports:QueryKind<String>;

	/** The FFI interfaces and projections registered, in order, by path and text. */
	public final ffi:QueryKind<String>;

	final moduleIds:Map<String, Int> = [];
	final moduleNames:Array<String> = [];
	final roots:Array<String> = [];
	final ffiSources:Array<String> = [];

	public function new(database:QueryDatabase) {
		this.database = database;
		sources = database.register(QueryKind.input("source", digestSource, sameSource, moduleName));
		embedded = database.register(QueryKind.input("embedded", digestString, sameString, moduleName));
		options = database.register(QueryKind.input("options", digestString, sameString));
		target = database.register(QueryKind.input("target", digestProfile, sameProfile));
		configuration = database.register(QueryKind.input("configuration", digestString, sameString));
		sourceRoots = database.register(QueryKind.input("source-roots", digestString, sameString));
		exports = database.register(QueryKind.input("exports", digestString, sameString));
		ffi = database.register(QueryKind.input("ffi", digestString, sameString));
	}

	/** The id of module `name`, interned the first time it is named. */
	public function moduleId(name:String):Int {
		var known = moduleIds.get(name);
		if (known != null)
			return known;
		var made = moduleNames.length;
		moduleIds.set(name, made);
		moduleNames.push(name);
		return made;
	}

	public function setSource(module:String, file:SourceFile):Void
		database.set(sources, moduleId(module), file);

	/** Module `module` left the program, with what its parse read. */
	public function removeSource(module:String):Void {
		var id = moduleId(module);
		database.remove(sources, id);
		database.remove(embedded, id);
	}

	public function setEmbedded(module:String, digests:String):Void
		database.set(embedded, moduleId(module), digests);

	public function setOptions(key:String):Void
		database.set(options, 0, key);

	public function setTarget(profile:compiler.ir.pipeline.TargetProfile):Void
		database.set(target, 0, profile);

	public function setConfiguration(identity:String, scopeIdentity:String):Void
		database.set(configuration, 0, identity + "\n" + scopeIdentity);

	/** A source root, given as its kind and path: one added again is a change, as the loader looks in it again. */
	public function addSourceRoot(root:String):Void {
		roots.push(root);
		database.set(sourceRoots, 0, roots.join("\n"));
	}

	public function setExports(sorted:Array<String>):Void
		database.set(exports, 0, sorted.join("\n"));

	public function addFfiSource(kind:String, path:String, text:String):Void {
		var digest = new Digest().string(text);
		ffiSources.push(kind + ":" + path + ":" + StringTools.hex(digest.first, 8) + StringTools.hex(digest.second, 8));
		database.set(ffi, 0, ffiSources.join("\n"));
	}

	/** The name of the module whose id is `id` (`moduleId`). */
	public function moduleName(id:Int):String
		return moduleNames[id];

	static function digestSource(file:SourceFile, digest:Digest):Void
		digest.string(file.path)
			.string(file.physicalPath)
			.bool(file.isStandardLibrarySource)
			.int(file.bytes.length)
			.digest(file.contentHash(), file.secondContentHash());

	static function sameSource(left:SourceFile, right:SourceFile):Bool
		return left.path == right.path && left.physicalPath == right.physicalPath
			&& left.isStandardLibrarySource == right.isStandardLibrarySource && left.text == right.text;

	static function digestString(value:String, digest:Digest):Void
		digest.string(value);

	static function sameString(left:String, right:String):Bool
		return left == right;

	static function digestProfile(profile:compiler.ir.pipeline.TargetProfile, digest:Digest):Void
		digest.string(profile.key());

	static function sameProfile(left:compiler.ir.pipeline.TargetProfile, right:compiler.ir.pipeline.TargetProfile):Bool
		return left.key() == right.key();
}
