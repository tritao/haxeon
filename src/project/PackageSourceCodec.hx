package project;

/** Shared JSON representation for manifest and lockfile package sources. */
class PackageSourceCodec {
	public static function encode(source:PackageSource):Dynamic
		return switch source {
			case PackageSource.Path(path): {path: path};
			case PackageSource.Workspace(path): {workspace: path};
			case PackageSource.Git(url, rev): {git: url, rev: rev};
			case PackageSource.Registry(registry, name, version): {registry: registry, name: name, version: version};
			case PackageSource.Haxelib(name, version): {haxelib: name, version: version};
		};

	public static function parse(raw:Dynamic, name:String, path:String):PackageSource {
		if (raw == null || !Reflect.isObject(raw) || Std.isOfType(raw, Array))
			throw '$path must be an object with a package source';
		var pathValue:Dynamic = Reflect.field(raw, "path"),
			workspaceValue:Dynamic = Reflect.field(raw, "workspace"),
			gitValue:Dynamic = Reflect.field(raw, "git"),
			registryValue:Dynamic = Reflect.field(raw, "registry"),
			haxelibValue:Dynamic = Reflect.field(raw, "haxelib"),
			count = (pathValue == null ? 0 : 1) + (workspaceValue == null ? 0 : 1) + (gitValue == null ? 0 : 1) + (registryValue == null ? 0 : 1)
				+ (haxelibValue == null ? 0 : 1);
		if (count != 1)
			throw '$path must declare exactly one package source';
		if (pathValue != null)
			return PackageSource.Path(requiredString(pathValue, "path", path));
		if (workspaceValue != null)
			return PackageSource.Workspace(requiredString(workspaceValue, "workspace", path));
		if (gitValue != null)
			return PackageSource.Git(requiredString(gitValue, "git", path), requiredField(raw, "rev", path));
		if (registryValue != null)
			return PackageSource.Registry(requiredString(registryValue, "registry", path), name, requiredField(raw, "version", path));
		return PackageSource.Haxelib(requiredString(haxelibValue, "haxelib", path), requiredField(raw, "version", path));
	}

	public static function equal(left:PackageSource, right:PackageSource):Bool
		return switch [left, right] {
			case [PackageSource.Path(a), PackageSource.Path(b)]: a == b;
			case [PackageSource.Workspace(a), PackageSource.Workspace(b)]: a == b;
			case [PackageSource.Git(aUrl, aRev), PackageSource.Git(bUrl, bRev)]: aUrl == bUrl && aRev == bRev;
			case [
				PackageSource.Registry(aRegistry, aName, aVersion),
				PackageSource.Registry(bRegistry, bName, bVersion)
			]: aRegistry == bRegistry && aName == bName && aVersion == bVersion;
			case [PackageSource.Haxelib(aName, aVersion), PackageSource.Haxelib(bName, bVersion)]: aName == bName && aVersion == bVersion;
			case _: false;
		};

	static function requiredField(raw:Dynamic, field:String, path:String):String
		return requiredString(Reflect.field(raw, field), field, path);

	static function requiredString(value:Dynamic, field:String, path:String):String {
		if (!Std.isOfType(value, String) || (cast value : String).length == 0)
			throw '$path requires a non-empty "$field" string';
		return cast value;
	}
}
