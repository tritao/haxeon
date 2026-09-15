package project;

import build.execution.ProcessRunner;
import haxe.crypto.Sha256;
import haxe.io.Path;
import sys.FileSystem;

/** Resolves a Git ref to a commit and checks it out into a source root. */
class GitSourceAcquirer implements SourceAcquirer {
	final sourceRoot:String;

	public function new(sourceRoot:String)
		this.sourceRoot = Path.normalize(sourceRoot);

	public function acquire(source:PackageSource, ownerRoot:String, packageId:PackageId):AcquiredSource
		return switch source {
			case PackageSource.Git(url, rev):
				var resolvedRevision = resolveRevision(url, rev),
					destination = Path.join([sourceRoot, "git", Sha256.encode(url + "\n" + resolvedRevision)]);
				if (!FileSystem.exists(destination))
					checkout(url, resolvedRevision, destination, packageId);
				new AcquiredSource(destination, PackageSource.Git(url, resolvedRevision), resolvedRevision);
			case _:
				throw 'Package "$packageId" source ${PackageSourceTools.describe(source)} is not supported by the Git acquirer';
		};

	function resolveRevision(url:String, rev:String):String {
		if (isSha(rev))
			return rev;
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
		var temporary = destination + '.checkout-${Std.int(Date.now().getTime())}';
		if (FileSystem.exists(temporary))
			throw 'Temporary Git checkout already exists: $temporary';
		var cloneStatus = ProcessRunner.run("git", ["clone", "--no-checkout", url, temporary], parent, new Map());
		if (cloneStatus != 0)
			throw 'Could not clone Git dependency "$packageId" from $url';
		var checkoutStatus = ProcessRunner.run("git", ["checkout", "--detach", revision], temporary, new Map());
		if (checkoutStatus != 0)
			throw 'Could not check out Git dependency "$packageId" at $revision';
		FileSystem.rename(temporary, destination);
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
