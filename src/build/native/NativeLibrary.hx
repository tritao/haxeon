package build.native;

class NativeLibrary {
	public final packageName:String;
	public final sources:Array<String>;
	public final includeDirs:Array<String>;

	public function new(packageName:String, sources:Array<String>, includeDirs:Array<String>) {
		this.packageName = packageName;
		this.sources = sources.copy();
		this.includeDirs = includeDirs.copy();
	}
}
