package compiler;

import haxe.io.Path;

/**
 * A package and its directory: the package `name` owns every source under `root` (`--source-package=NAME=DIRECTORY`), and
 * `friends` may use its internal declarations (`--package-friend=NAME=FRIEND`, from the manifest's `package.friends`).
 */
class SourcePackage {
	public final name:String;
	public final root:String;
	public final friends:Array<String>;

	public function new(name:String, root:String, ?friends:Array<String>) {
		this.name = name;
		this.root = root;
		this.friends = friends == null ? [] : friends.copy();
	}

	/** The package `NAME=DIRECTORY` states, or null when it is not one. */
	public static function parse(value:String):Null<SourcePackage> {
		var separator = value.indexOf("=");
		return separator <= 0 || separator == value.length - 1 ? null : new SourcePackage(value.substr(0, separator),
			value.substr(separator + 1));
	}

	/** The flag's value, which `parse` reads back. */
	public function argument():String
		return name + "=" + root;
}

/**
 * Which package each source belongs to: the one whose directory holds it, the innermost when one package's directory is inside
 * another's (a checkout's packages/ under its root). A source in no package's directory (the standard library, a lone file, an
 * FFI module generated into a build) belongs to none. `internal` declarations are shared by the sources of one package, and the
 * API model gives each source relative to its package's directory.
 */
class SourcePackages {
	final entries:Array<{name:String, root:String}>;
	final owners:Map<String, Null<{name:String, file:String}>> = [];
	final friends:Map<String, Array<String>> = [];

	public function new(packages:Array<SourcePackage>) {
		for (entry in packages)
			if (entry.friends.length > 0)
				friends.set(entry.name, entry.friends);
		entries = [for (entry in packages) {
			name: entry.name, root: Path.addTrailingSlash(absolute(entry.root))
		}];
		entries.sort((left, right) -> right.root.length - left.root.length);
	}

	/** The package holding the source at `path`, with the source's path relative to the package's directory. */
	public function locate(path:String):Null<{name:String, file:String}> {
		if (owners.exists(path))
			return owners.get(path);
		var full = absolute(path), found:Null<{name:String, file:String}> = null;
		for (entry in entries)
			if (StringTools.startsWith(full, entry.root)) {
				found = {name: entry.name, file: full.substr(entry.root.length)};
				break;
			}
		owners.set(path, found);
		return found;
	}

	/**
	 * Whether the code of the package `user` may use what the package `owner` declares `internal`: its own, or a friend's
	 * it names. Null is the sources outside any package, which share theirs.
	 */
	public function mayUseInternals(owner:Null<String>, user:Null<String>):Bool
		return owner == user || owner != null && user != null && friends.exists(owner)
			&& friends.get(owner).indexOf(user) >= 0;

	/** The name of the package holding the source at `path`, or null for none. */
	public function packageOf(path:String):Null<String> {
		var found = locate(path);
		return found == null ? null : found.name;
	}

	public static function absolute(path:String):String
		return Path.normalize(Path.isAbsolute(path) ? path : Path.join([Sys.getCwd(), path]));
}
