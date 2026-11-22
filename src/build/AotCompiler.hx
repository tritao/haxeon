package build;

import build.execution.ContentDigest;
import build.execution.ContentDigestCache;
import haxe.crypto.Sha256;
import haxe.io.Bytes;
import haxe.io.Path;
import sys.FileSystem;
import sys.io.File;

/**
 * Haxeon built ahead of time to C (`--target=hlc`, docs/design/AOT_BACKEND.md): the executable `haxeon-aot` beside the VM,
 * one program for the CLI, which the `haxeon` launcher runs, and for every role in which the CLI runs the compiler
 * (`tools.CompilerExecutable`: a compile, a compile server, the language server). It starts in a tenth of the time the VM takes
 * to JIT the bytecode. The CLI's sources are the compiler's, so one stamp covers both. A release ships it prebuilt for
 * its platform, so a user needs no C compiler; in a checkout `haxeon dev aot` builds it (`tools.dev.AotBuild`).
 *
 * A release also ships the compiler's roles as bytecode, `haxeon-compiler.hl` beside the VM (`tools.dev.ReleasePackage`), which
 * it runs on the VM when it has no executable, as it runs the CLI's own bytecode (`haxeon-cli.hl`): a release has no pinned Haxe
 * to build them from its sources, as a checkout does.
 *
 * Each is used only while it is current: built from the sources the CLI would otherwise build to bytecode. Its stamp
 * (`haxeon-aot.sources`, `haxeon-compiler.hl.sources`) holds the digest of those sources when it was built; a program without
 * one, or with another digest, is ignored and the CLI and the compiler run on the VM as before. So an edit in a checkout never
 * runs an older CLI or compiler, and nothing chooses between them but what is installed. A release ships no compiler sources,
 * as its compiler cannot change: there the digest to match is the one its marker records (`HaxeonRelease.COMPILER_SOURCES`),
 * written when the release was made.
 */
class AotCompiler {
	public static inline final NAME = "haxeon-aot";

	/** Bump when what the digest covers changes. */
	static inline final FORMAT = 1;

	/**
	 * Whether `program` says, once, that the executable is stale and the compiler runs on the VM instead (`staleNotice`). The CLI
	 * turns it on for builds that print progress, so a quiet build or a script says nothing.
	 */
	public static var announceStale = false;

	static var staleAnnounced = false;

	/** How long before a digest a file must have last changed for the digest to be kept (`ContentDigestCache.racyMarginSeconds`). */
	static inline final RACY_MARGIN_SECONDS = 3.0;

	/** Where the executable is, whether or not it exists. */
	public static function executable(home:String):String
		return HashLinkPath.executable(home, NAME);

	/** Where the compiler's bytecode for the VM is, whether or not it exists. */
	public static function bytecode(home:String):String
		return Path.join([HashLinkPath.directory(home), "haxeon-compiler.hl"]);

	/** The stamp beside the executable: the digest of the sources it was built from. */
	public static function stamp(home:String):String
		return Path.join([HashLinkPath.directory(home), NAME + ".sources"]);

	/** The stamp beside the bytecode. */
	public static function bytecodeStamp(home:String):String
		return bytecode(home) + ".sources";

	/**
	 * The executable when it was built from the compiler in `compilerSource` (a `src` directory, as `CompilerSources` takes) and
	 * `home`'s standard library, else null: when it is missing, has no stamp, or is stale.
	 */
	public static function current(home:String, compilerSource:String, ?digests:ContentDigestCache):Null<String> {
		var digest = new LazyDigest(home, compilerSource, digests);
		return digest.matches(executable(home), stamp(home)) ? executable(home) : null;
	}

	/** The bytecode when it was built from those sources, else null. */
	public static function currentBytecode(home:String, compilerSource:String,
			?digests:ContentDigestCache):Null<String> {
		var digest = new LazyDigest(home, compilerSource, digests);
		return digest.matches(bytecode(home), bytecodeStamp(home)) ? bytecode(home) : null;
	}

	/**
	 * The command that runs the compiler without building it from its sources, to which a role's arguments are added (`serve
	 * STATE`, `lsp`, or a compile's): the executable when it is current, else the VM with the bytecode when that is current, else
	 * null. A stale executable is said once (`staleNotice`) when `announceStale` is on.
	 */
	public static function program(home:String, compilerSource:String,
			?digests:ContentDigestCache):Null<CompilerProgram> {
		var digest = new LazyDigest(home, compilerSource, digests), native = executable(home);
		if (digest.matches(native, stamp(home)))
			return {command: [native], native: true};
		if (announceStale && !staleAnnounced && FileSystem.exists(native)) {
			staleAnnounced = true;
			BuildOutput.error(staleNotice());
		}
		var code = bytecode(home);
		return digest.matches(code, bytecodeStamp(home)) ? {
			command: [HashLinkPath.executable(home), code],
			native: false
		} : null;
	}

	/** What a build says when the executable is stale, so a checkout's slower start has a stated cause and remedy. */
	public static function staleNotice():String
		return 'note: $NAME is older than the sources, so the CLI and the compiler run on the VM (a slower start); '
			+ 'rebuild it with "haxeon dev aot"';

	/**
	 * The digest of every file of the compiler's sources (`CompilerSources.roots`) and of the standard library it is built with, by
	 * path relative to its root and content, so it does not depend on where a checkout or a release is unpacked.
	 *
	 * Every start of the CLI asks, so the digest is kept in `out` with the stat signature of the files it was made from (each one's
	 * device, inode, size and times, and the list of them) and read back while that signature holds: then no file is read. As in
	 * `ContentDigestCache`, it is kept only when no file changed within `RACY_MARGIN_SECONDS` of the hash, since timestamps are whole
	 * seconds and an edit that keeps the size within the same second would not change the signature.
	 */
	public static function sourcesDigest(home:String, compilerSource:String, ?digests:ContentDigestCache):String {
		var started = Sys.time(),
			roots = CompilerSources.roots(compilerSource).concat([Path.join([home, "stdlib"])]),
			files:Array<SourceFile> = [],
			signature = new StringBuf();
		signature.add('format $FORMAT\n');
		for (index in 0...roots.length) {
			signature.add('root $index ${roots[index]}\n');
			listTree(roots[index], "", index, files, signature);
		}
		var key = ContentDigest.makeHex(Bytes.ofString(signature.toString())), cache = digestCache(home);
		try {
			var fields = StringTools.trim(File.getContent(cache)).split(" ");
			if (fields.length == 2 && fields[0] == key && fields[1].length == key.length)
				return fields[1];
		} catch (_:Dynamic) {}
		if (digests == null)
			digests = new ContentDigestCache();
		var text = new StringBuf(), root = -1, settled = true, limit = (started - RACY_MARGIN_SECONDS) * 1000.0;
		text.add('format $FORMAT\n');
		for (file in files) {
			for (index in root + 1...file.root + 1)
				text.add('root $index\n');
			root = file.root;
			text.add('${file.relative} ${digests.file(file.path)}\n');
			settled = settled && file.changed <= limit;
		}
		for (index in root + 1...roots.length)
			text.add('root $index\n');
		var digest = Sha256.encode(text.toString());
		if (settled)
			try {
				// Written aside under a name of its own and renamed, so a concurrent reader or writer never sees part of it.
				var temporary = cache + ".tmp." + Std.random(1000000000);
				FileSystem.createDirectory(Path.directory(cache));
				File.saveContent(temporary, '$key $digest\n');
				FileSystem.rename(temporary, cache);
			} catch (_:Dynamic) {}
		return digest;
	}

	/** Where `sourcesDigest` keeps its last digest. */
	static function digestCache(home:String):String
		return Path.join([home, "out", NAME + ".sources-digest"]);

	/** The files below `relative` in `root`, in the digest's order, each with its stat signature in `signature`. */
	static function listTree(root:String, relative:String, rootIndex:Int, into:Array<SourceFile>,
			signature:StringBuf):Void {
		var entries = FileSystem.readDirectory(relative == "" ? root : Path.join([root, relative]));
		entries.sort((left, right) -> left < right ? -1 : (left > right ? 1 : 0));
		for (entry in entries) {
			var child = relative == "" ? entry : relative + "/" + entry, path = Path.join([root, child]);
			if (FileSystem.isDirectory(path))
				listTree(root, child, rootIndex, into, signature);
			else {
				var stat = FileSystem.stat(path), modified = stat.mtime.getTime(), changed = stat.ctime.getTime();
				signature.add('$child ${stat.dev}:${stat.ino}:${stat.size}:$modified:$changed\n');
				into.push({
					root: rootIndex,
					relative: child,
					path: path,
					changed: Math.max(modified, changed)
				});
			}
		}
	}
}

/**
 * The sources' digest, computed at most once and only when a stamp is there to compare it with; in a release, the one its marker
 * records.
 */
private class LazyDigest {
	final home:String;
	final compilerSource:String;
	final digests:Null<ContentDigestCache>;
	var digest:Null<String> = null;

	public function new(home:String, compilerSource:String, digests:Null<ContentDigestCache>) {
		this.home = home;
		this.compilerSource = compilerSource;
		this.digests = digests;
	}

	/** Whether `path` and its stamp `stampPath` exist and the stamp holds the sources' digest. */
	public function matches(path:String, stampPath:String):Bool {
		try {
			if (!FileSystem.exists(path) || !FileSystem.exists(stampPath))
				return false;
			if (digest == null)
				digest = HaxeonRelease.isRelease(home) ? HaxeonRelease.field(home,
					HaxeonRelease.COMPILER_SOURCES) : AotCompiler.sourcesDigest(home, compilerSource, digests);
			return digest != null && StringTools.trim(File.getContent(stampPath)) == digest;
		} catch (_:Dynamic) {
			return false;
		}
	}
}

/** How the CLI runs a compiler it did not build from sources (`AotCompiler.program`). */
typedef CompilerProgram = {
	/** The program and the arguments before a role's. */
	final command:Array<String>;

	/** The executable built ahead of time, rather than the VM running bytecode. */
	final native:Bool;
}

/** A file `AotCompiler.sourcesDigest` covers. */
private typedef SourceFile = {
	final root:Int;
	final relative:String;
	final path:String;

	/** The later of its modification and status change times, in milliseconds. */
	final changed:Float;
}
