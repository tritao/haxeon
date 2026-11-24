package build;

enum ArtifactKind {
	Diagnostics;
	HashLinkModule;

	/** The program as C on the HashLink runtime (`--target=hlc`), which an app's runner compiles and links (docs/design/PROJECT_BUILDS.md). */
	CModule;

	HashLinkPatch;
	WasmModule;
	NativeObject;
	NativeStaticLibrary;
	NativeSharedLibrary;
	FfiNativeSharedLibrary;
	FfiInterface;
	Executable;
	NativeRuntime;
}

/** A logical output and its artifact-level requirements. */
class Artifact {
	public final id:ArtifactId;
	public final dependencies:Array<ArtifactId>;
	public final details:Map<String, String>;

	public function new(id:ArtifactId, ?dependencies:Array<ArtifactId>, ?details:Map<String, String>) {
		this.id = id;
		this.dependencies = dependencies == null ? [] : dependencies.copy();
		this.dependencies.sort((a, b) -> Reflect.compare(a.key(), b.key()));
		this.details = new Map();
		if (details != null)
			for (key in details.keys())
				this.details.set(key, details.get(key));
	}

	public static function kindName(kind:ArtifactKind):String
		return switch kind {
			case Diagnostics: "Diagnostics";
			case HashLinkModule: "HashLinkModule";
			case CModule: "CModule";
			case HashLinkPatch: "HashLinkPatch";
			case WasmModule: "WasmModule";
			case NativeObject: "NativeObject";
			case NativeStaticLibrary: "NativeStaticLibrary";
			case NativeSharedLibrary: "NativeSharedLibrary";
			case FfiNativeSharedLibrary: "FfiNativeSharedLibrary";
			case FfiInterface: "FfiInterface";
			case Executable: "Executable";
			case NativeRuntime: "NativeRuntime";
		};
}
