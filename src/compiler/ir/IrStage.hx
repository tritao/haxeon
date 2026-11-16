package compiler.ir;

import compiler.ir.Ir.IrProgram;

/**
 * One named step of an `IrPipeline` stage list: an existing pass (or a group of calls that ran back to back) wrapped as it is, from
 * the program to the program. The lists are built once; a build runs them with its own `IrPipelineContext`. `IrAssemblyStage` is the
 * same for the program under assembly (`IrAssembly`): two classes rather than one with a type parameter, because the self-hosted
 * compiler erases the type parameter of a function-typed field to one signature.
 */
class IrStage extends IrStageHooks {
	public final run:(IrProgram, IrPipelineContext) -> IrProgram;

	/** When the stage runs; null runs it always. Read once per run, as the stage is reached. */
	public var enabled(default, null):Null<(IrProgram, IrPipelineContext) -> Bool> = null;

	public function new(name:String, run:(IrProgram, IrPipelineContext) -> IrProgram) {
		super(name);
		this.run = run;
	}

	public function when(predicate:(IrProgram, IrPipelineContext) -> Bool):IrStage {
		enabled = predicate;
		return this;
	}

	public function measured():IrStage {
		setMetered();
		return this;
	}
}

/** What every stage declares besides its pass: its name, its metering and the early prune's check hooks. */
class IrStageHooks {
	/** The stage's name; for a metered stage also the name its allocation is recorded under (`IrPassMeter`). */
	public final name:String;

	/** The allocation of the stage is recorded under `name`. */
	public var metered(default, null) = false;

	/**
	 * Check mode of the early prune (`IrEntryPrune.checkRemoved`): after this stage, run or not, nothing may call a function the prune
	 * removed. The text names the stage in the failure.
	 */
	public var pruneCheck(default, null):Null<String> = null;

	/** The early prune: after this stage, run or not, the pipeline watches what it removed until the list ends (`IrEntryPrune.watch`). */
	public var prunePoint(default, null) = false;

	function new(name:String)
		this.name = name;

	function setMetered():Void
		metered = true;

	function setPruneCheck(label:Null<String>):Void
		pruneCheck = label == null ? name : label;

	function setPrunePoint():Void
		prunePoint = true;

	/** The check-mode hooks after `stage`, whether it ran or not; `functions` are the program's after it. */
	public static function after(stage:IrStageHooks, functions:Array<IrFunction>, context:IrPipelineContext):Void {
		var label = stage.pruneCheck;
		if (label != null && context.checkPrune)
			IrEntryPrune.checkRemoved(label, functions, context.pruned);
		if (stage.prunePoint) {
			context.checkPrune = context.pruneFromEntry && IrEntryPrune.checking();
			IrEntryPrune.watch(context.checkPrune ? context.pruned : null);
		}
	}
}

/** A stage of the program under assembly. */
class IrAssemblyStage extends IrStageHooks {
	public final run:(IrAssembly, IrPipelineContext) -> IrAssembly;

	/** When the stage runs; null runs it always. Read once per run, as the stage is reached. */
	public var enabled(default, null):Null<(IrAssembly, IrPipelineContext) -> Bool> = null;

	public function new(name:String, run:(IrAssembly, IrPipelineContext) -> IrAssembly) {
		super(name);
		this.run = run;
	}

	public function when(predicate:(IrAssembly, IrPipelineContext) -> Bool):IrAssemblyStage {
		enabled = predicate;
		return this;
	}

	public function measured():IrAssemblyStage {
		setMetered();
		return this;
	}

	/** `label` names the stage in a failure; the stage name by default. */
	public function checksPrune(?label:String):IrAssemblyStage {
		setPruneCheck(label);
		return this;
	}

	public function prunes():IrAssemblyStage {
		setPrunePoint();
		return this;
	}
}

/** An ordered list of program stages and the loop that runs them, with the metering the stages declare. */
class IrStageList {
	public final name:String;
	public final stages:Array<IrStage>;

	public function new(name:String, stages:Array<IrStage>) {
		this.name = name;
		this.stages = stages;
	}

	public function run(program:IrProgram, context:IrPipelineContext):IrProgram {
		for (stage in stages) {
			var enabled = stage.enabled;
			if (enabled == null || enabled(program, context)) {
				if (stage.metered) {
					var before = compiler.core.IrPassMeter.start();
					program = stage.run(program, context);
					compiler.core.IrPassMeter.stop(stage.name, before);
				} else
					program = stage.run(program, context);
			}
		}
		return program;
	}

	/** The stage names in order. */
	public function names():Array<String>
		return [for (stage in stages) stage.name];
}

/** The stage list of the program under assembly, with the metering and the early prune's check hooks its stages declare. */
class IrAssemblyStageList {
	public final name:String;
	public final stages:Array<IrAssemblyStage>;

	public function new(name:String, stages:Array<IrAssemblyStage>) {
		this.name = name;
		this.stages = stages;
	}

	public function run(assembly:IrAssembly, context:IrPipelineContext):IrAssembly {
		var watches = false;
		for (stage in stages) {
			var enabled = stage.enabled;
			if (enabled == null || enabled(assembly, context)) {
				if (stage.metered) {
					var before = compiler.core.IrPassMeter.start();
					assembly = stage.run(assembly, context);
					compiler.core.IrPassMeter.stop(stage.name, before);
				} else
					assembly = stage.run(assembly, context);
			}
			IrStageHooks.after(stage, assembly.functions, context);
			watches = watches || stage.prunePoint;
		}
		// The watch ends with the list, as the prune's check mode covers only the passes after it.
		if (watches)
			IrEntryPrune.watch(null);
		return assembly;
	}

	/** The stage names in order. */
	public function names():Array<String>
		return [for (stage in stages) stage.name];
}
