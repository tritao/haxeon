package build.execution;

enum ActionKind {
	Process(command:String, arguments:Array<String>, cwd:String, environment:Map<String, String>);
	Compiler(command:String, arguments:Array<String>, cwd:String, environment:Map<String, String>, invoke:Void->Int);
}

/** A concrete, executable node in the lowered build graph. */
class ExecutionAction {
	public final id:ActionId;
	public final dependencies:Array<ActionId>;
	public final inputs:Array<String>;
	public final outputs:Array<String>;
	public final description:String;
	public final action:ActionKind;
	/** Keep ordering/failure dependencies without invalidating independently compiled outputs. */
	public final fingerprintDependencies:Bool;
	/** Delegated build tools must check their own complete dependency graph on every build. */
	public final alwaysRun:Bool;

	public function new(id:ActionId, dependencies:Array<ActionId>, inputs:Array<String>, outputs:Array<String>, description:String, action:ActionKind,
			fingerprintDependencies:Bool = true, alwaysRun:Bool = false) {
		this.id = id;
		this.dependencies = dependencies.copy();
		this.dependencies.sort((left, right) -> Reflect.compare(left.key(), right.key()));
		this.inputs = inputs.copy();
		this.inputs.sort(Reflect.compare);
		this.outputs = outputs.copy();
		this.outputs.sort(Reflect.compare);
		this.description = description;
		this.action = action;
		this.fingerprintDependencies = fingerprintDependencies;
		this.alwaysRun = alwaysRun;
	}
}
