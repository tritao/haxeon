package project;

import build.execution.ProcessRunner;
import haxe.crypto.Sha256;
import haxe.io.Path;
import sys.FileSystem;

/**
 * Resolves a Git ref to a commit and checks it out into a source root. Offline, it neither resolves a ref nor clones: the
 * commit must be named (as the lockfile names it) and its checkout already in the cache.
 */
class GitSourceAcquirer implements SourceAcquirer {
	final sourceRoot:String;
	final offline:Bool;

	public function new(sourceRoot:String, offline:Bool = false) {
		this.sourceRoot = Path.normalize(sourceRoot);
		this.offline = offline;
	}

	public function acquire(source:PackageSource, ownerRoot:String, packageId:PackageId):AcquiredSource
		return switch source {
			case PackageSource.Git(url, rev):
				var resolvedRevision = resolveRevision(url, rev),
					destination = Path.join([sourceRoot, "git", Sha256.encode(url + "\n" + resolvedRevision)]);
				if (!FileSystem.exists(destination)) {
					if (offline)
						throw 'Git dependency "$packageId" at $resolvedRevision is not in the source cache; run "haxeon install"';
					checkout(url, resolvedRevision, destination, packageId);
				}
					else
					validateCheckout(destination, resolvedRevision, packageId);
				new AcquiredSource(destination, PackageSource.Git(url, resolvedRevision), resolvedRevision);
			case _:
				throw 'Package "$packageId" source ${PackageSourceTools.describe(source)} is not supported by the Git acquirer';
		};

	function resolveRevision(url:String, rev:String):String {
		if (isSha(rev))
			return rev;
		if (offline)
			throw 'Git dependency $url@$rev is not locked to a commit; run "haxeon install" to write haxeon.lock';
		var result = ProcessRunner.capture("git", ["ls-remote", url, rev]);
		if (result.status != 0)
			throw 'Could not resolve Git dependency $url@$rev: ${StringTools.trim(result.output)}';
		for (line in result.output.split("\n")) {
			var fields = line.split("\t");
			if (fields.length >= 2 && isSha(StringTools.trim(fields[0])))
				return StringTools.trim(fields[0]);
		}
		throw 'Git dependency $url has no revision matching "$rev"';
	}

	function checkout(url:String, revision:String, destination:String, packageId:PackageId):Void {
		var parent = Path.directory(destination);
		ensureDirectory(parent);
		// Milliseconds overflow Std.int, which saturated every name to the same one; a random part keeps two clones started in
		// the same millisecond apart.
		var temporary = destination + '.checkout-${Math.ffloor(Date.now().getTime())}-${Std.random(0x7FFFFFFF)}';
		if (FileSystem.exists(temporary))
			throw 'Temporary Git checkout already exists: $temporary';
		// The checkout is named by a 64-character hash under the cache, and with Git's own object paths under it that passes
		// Windows' 260-character limit from a moderately deep cache ("Filename too long"). core.longpaths, set in the new
		// repository before it fetches, lets Git for Windows write longer paths; other Gits ignore it.
		var cloneStatus = ProcessRunner.run("git", [
			"clone",
			"-c",
			"core.longpaths=true",
			"--no-checkout",
			url,
			temporary
		], parent,
			new Map());
		if (cloneStatus != 0)
			throw 'Could not clone Git dependency "$packageId" from $url';
		var checkoutStatus = ProcessRunner.run("git", ["checkout", "--detach", revision], temporary, new Map());
		if (checkoutStatus != 0)
			throw 'Could not check out Git dependency "$packageId" at $revision';
		FileSystem.rename(temporary, destination);
	}

	function validateCheckout(destination:String, revision:String, packageId:PackageId):Void {
		var result = ProcessRunner.capture("git", ["-C", destination, "rev-parse", "HEAD"]);
		if (result.status != 0 || StringTools.trim(result.output) != revision)
			throw 'Cached Git source for "$packageId" is not immutable at $revision';
	}

	static function isSha(value:String):Bool {
		if (value == null || value.length != 40)
			return false;
		for (index in 0...value.length) {
			var code = value.charCodeAt(index);
			if (!((code >= 48 && code <= 57) || (code >= 65 && code <= 70) || (code >= 97 && code <= 102)))
				return false;
		}
		return true;
	}

	static function ensureDirectory(path:String):Void {
		if (path == null || path == "" || path == "." || FileSystem.exists(path))
			return;
		var parent = Path.directory(path);
		if (parent != path && parent != "")
			ensureDirectory(parent);
		if (!FileSystem.exists(path))
			FileSystem.createDirectory(path);
	}
}
