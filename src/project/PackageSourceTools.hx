package project;

class PackageSourceTools {
	public static function describe(source:PackageSource):String
		return switch source {
			case Path(path): 'path:$path';
			case Workspace(path): 'workspace:$path';
			case Git(url, rev): 'git:$url@$rev';
			case Registry(registry, name, version): 'registry:$registry/$name@$version';
			case Haxelib(name, version): 'haxelib:$name@$version';
		};
}
