package build;

import build.execution.ContentDigestCache;
import haxe.crypto.Sha256;
import haxe.io.Path;
import sys.FileSystem;
import sys.io.File;

/**
 * The compiler built ahead of time to C (`--target=hlc`, docs/design/AOT_BACKEND.md): the executable `haxeon-compiler` beside the
 * VM, one program for every role in which the CLI runs the compiler (`tools.CompilerExecutable`: a compile, a compile server, the
 * language server). It starts in a tenth of the time the VM takes to JIT the compiler's bytecode. A release ships it prebuilt for
 * its platform, so a user needs no C compiler; in a checkout `haxeon dev aot-compiler` builds it (`tools.dev.AotCompilerBuild`).
 *
 * It is used only while it is current: built from the compiler sources the CLI would otherwise build to bytecode. Its stamp,
 * `haxeon-compiler.sources` beside it, holds the digest of those sources when it was built; an executable without one, or with
 * another digest, is ignored and the compiler runs on the VM as before. So an edit to the compiler in a checkout never runs an
 * older compiler, and nothing chooses between the two but what is installed.
 */
class AotCompiler {
	public static inline final NAME = "haxeon-compiler";

	/** Bump when what the digest covers changes. */
	static inline final FORMAT = 1;

	/** Where the executable is, whether or not it exists. */
	public static function executable(home:String):String
		return HashLinkPath.executable(home, NAME);

	/** The stamp beside the executable: the digest of the sources it was built from. */
	public static function stamp(home:String):String
		return Path.join([HashLinkPath.directory(home), NAME + ".sources"]);

	/**
	 * The executable when it was built from the compiler in `compilerSource` (a `src` directory, as `CompilerSources` takes) and
	 * `home`'s standard library, else null: when it is missing, has no stamp, or is stale.
	 */
	public static function current(home:String, compilerSource:String, ?digests:ContentDigestCache):Null<String> {
		try {
			var path = executable(home), stampPath = stamp(home);
			if (!FileSystem.exists(path) || !FileSystem.exists(stampPath))
				return null;
			return StringTools.trim(File.getContent(stampPath)) == sourcesDigest(home, compilerSource, digests)
				? path : null;
		} catch (_:Dynamic) {
			return null;
		}
	}

	/**
	 * The digest of every file of the compiler's sources (`CompilerSources.roots`) and of the standard library it is built with, by
	 * path relative to its root and content, so it does not depend on where a checkout or a release is unpacked.
	 */
	public static function sourcesDigest(home:String, compilerSource:String, ?digests:ContentDigestCache):String {
		if (digests == null)
			digests = new ContentDigestCache();
		var text = new StringBuf();
		text.add('format $FORMAT\n');
		var roots = CompilerSources.roots(compilerSource).concat([Path.join([home, "stdlib"])]);
		for (index in 0...roots.length) {
			text.add('root $index\n');
			digestTree(roots[index], "", text, digests);
		}
		return Sha256.encode(text.toString());
	}

	static function digestTree(root:String, relative:String, into:StringBuf, digests:ContentDigestCache):Void {
		var entries = FileSystem.readDirectory(relative == "" ? root : Path.join([root, relative]));
		entries.sort((left, right) -> left < right ? -1 : (left > right ? 1 : 0));
		for (entry in entries) {
			var child = relative == "" ? entry : relative + "/" + entry, path = Path.join([root, child]);
			if (FileSystem.isDirectory(path))
				digestTree(root, child, into, digests);
			else
				into.add('$child ${digests.file(path)}\n');
		}
	}
}
