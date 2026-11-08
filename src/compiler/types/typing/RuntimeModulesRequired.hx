package compiler.types.typing;

/**
	Thrown by the typer before it types any body when the declarations alone show that the program needs runtime modules it
	does not contain yet. The frontend adds them and starts over, so no function is typed against a representation that the
	missing module would change.
**/
class RuntimeModulesRequired {
	public final dependencies:Array<{var functionName:String; var target:String;}>;

	public function new(dependencies:Array<{var functionName:String; var target:String;}>)
		this.dependencies = dependencies;
}
