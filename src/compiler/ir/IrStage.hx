package compiler.ir;

import compiler.ir.Ir.IrProgram;
import compiler.ir.IrEntryPrune.IrPruneWatch;
import compiler.ir.IrStageMemo.IrLineage;

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
}

/** What every stage declares besides its pass: its name and the early prune's check hooks. */
class IrStageHooks {
	/** The stage's name, also the name its time and allocation are recorded under (`IrPassMeter`). */
	public final name:String;

	/**
	 * Check mode of the early prune (`IrEntryPrune.checkRemoved`): after this stage, run or not, nothing may call a function the prune
	 * removed. The text names the stage in the failure.
	 */
	public var pruneCheck(default, null):Null<String> = null;

	/** The early prune: after this stage, run or not, the pipeline watches what it removed until the list ends (`IrEntryPrune.watch`). */
	public var prunePoint(default, null) = false;

	function new(name:String)
		this.name = name;

	function setPruneCheck(label:Null<String>):Void
		pruneCheck = label == null ? name : label;

	function setPrunePoint():Void
		prunePoint = true;

	/**
	 * The stage census: marks every function of a stage's input as input and not read (`IrFunction.census`) before the stage runs;
	 * returns how many there are.
	 */
	public static function censusStart(functions:Array<IrFunction>):Int {
		for (fn in functions)
			fn.census = IrFunction.CENSUS_INPUT;
		return functions.length;
	}

	/**
	 * Records in `meter` what the stage did to the functions: how many it read, made (an object not in its input) and dropped (an
	 * input function not in its output), and clears the marks of its output. A dropped function counts as read, as a stage reads
	 * what it replaces; its marks stay until a stage is given it again.
	 */
	public static function census(name:String, inputCount:Int, output:Array<IrFunction>,
			meter:compiler.core.IrPassMeter):Void {
		var read = 0, made = 0, kept = 0;
		for (fn in output) {
			var marks = fn.census;
			if (marks & IrFunction.CENSUS_INPUT != 0)
				kept++;
			else
				made++;
			if (marks & IrFunction.CENSUS_READ != 0)
				read++;
			fn.census = 0;
		}
		meter.functions(name, read + inputCount - kept, made, inputCount - kept);
	}

	/** The check-mode hooks after `stage`, whether it ran or not; `functions` are the program's after it. */
	public static function after(stage:IrStageHooks, functions:Array<IrFunction>, context:IrPipelineContext):Void {
		var label = stage.pruneCheck;
		if (label != null && context.checkPrune)
			IrEntryPrune.checkRemoved(label, functions, context.pruned);
		if (stage.prunePoint) {
			context.checkPrune = context.pruneFromEntry && context.options.checkReuse;
			IrEntryPrune.watching(context.checkPrune ? new IrPruneWatch(context.pruned, context.prunedMethods) : null);
		}
	}

	/**
	 * After a stage that ran: every body of the program reads its types from one table, the session's (`IrInlineCache.types`),
	 * else the first body's, so type ids mean the same in every body a stage reads, splices or compares.
	 */
	static function checkTables(functions:Array<IrFunction>, context:IrPipelineContext):Void {
		var cache = context.inlineCache, table:Null<IrTypeIds> = cache == null ? null : cache.types;
		for (fn in functions) {
			var body = fn.body;
			if (body == null)
				continue;
			if (table == null)
				table = body.types;
			else if (body.types != table)
				throw new compiler.core
					.InternalError('IR function ${fn.name} has a body made with another type table than the program\'s');
		}
	}

	/**
	 * After a stage that ran: in a compile that keeps no session, a function that has a body keeps only its body, the objects
	 * the stage made it from or decoded to read it included. A session keeps them while a cache before the encode point reads them.
	 */
	public static function release(functions:Array<IrFunction>, context:IrPipelineContext):Void {
		checkTables(functions, context);
		if (context.options.keepSession)
			return;
		for (fn in functions)
			if (fn.body != null)
				fn.releaseDecoded();
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

	/** `label` names the stage in a failure; the stage name by default. */
	public function checksPrune(?label:String):IrAssemblyStage {
		setPruneCheck(label);
		return this;
	}

	public function prunes():IrAssemblyStage {
		setPrunePoint();
		return this;
	}

	/** The stage keeps the lineage of the functions itself (`IrFunctionStages`), so the list does not settle after it. */
	public var memoizes(default, null) = false;

	/** The encode point: the lineage of the functions (`IrLineage`) ends after this stage, as the stages after it edit bodies. */
	public var encodePoint(default, null) = false;

	public function memoized():IrAssemblyStage {
		memoizes = true;
		return this;
	}

	public function encodes():IrAssemblyStage {
		encodePoint = true;
		return this;
	}

	/** Runs the stage; before the encode point of a session, its changes are settled into the lineage (`IrLineage.settle`). */
	public function runSettled(assembly:IrAssembly, context:IrPipelineContext):IrAssembly {
		var result = run(assembly, context), lineage = context.lineage;
		if (lineage != null && !memoizes)
			lineage.settle(name, result.functions);
		return result;
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
				if (context.meter != null) {
					var meter:compiler.core.IrPassMeter = context.meter,
						input = IrStageHooks.censusStart(program.functions),
						before = meter.start();
					program = stage.run(program, context);
					meter.stop(stage.name, before);
					IrStageHooks.census(stage.name, input, program.functions, meter);
				} else
					program = stage.run(program, context);
				IrStageHooks.release(program.functions, context);
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
		var watches = false, memos = context.stageMemos, generated = context.generatedVersion;
		// A session reuses what the stages before the encode point made of each function (`IrStageMemos`).
		context.lineage = null;
		if (memos != null && generated != null && context.options.keepSession) {
			var meter = context.meter, before = meter == null ? null : meter.start();
			context.lineage = IrLineage.start(memos, assembly.functions, generated, context.options.checkReuse);
			if (meter != null && before != null)
				meter.stop(IrLineage.INPUT, before);
		}
		try {
			for (stage in stages) {
				var enabled = stage.enabled;
				if (enabled == null || enabled(assembly, context)) {
					if (context.meter != null) {
						var meter:compiler.core.IrPassMeter = context.meter,
							input = IrStageHooks.censusStart(assembly.functions),
							before = meter.start();
						assembly = stage.runSettled(assembly, context);
						meter.stop(stage.name, before);
						IrStageHooks.census(stage.name, input, assembly.functions, meter);
					} else
						assembly = stage.runSettled(assembly, context);
					IrStageHooks.release(assembly.functions, context);
				}
				if (stage.encodePoint)
					context.lineage = null;
				IrStageHooks.after(stage, assembly.functions, context);
				watches = watches || stage.prunePoint;
			}
		} catch (error:haxe.Exception) {
			context.lineage = null;
			// A pass that throws ends the run, and the watch with it: the next compile on this thread must not inherit it.
			if (watches)
				IrEntryPrune.watching(null);
			throw error;
		}
		// The watch ends with the list, as the prune's check mode covers only the passes after it.
		if (watches)
			IrEntryPrune.watching(null);
		return assembly;
	}

	/** The stage names in order. */
	public function names():Array<String>
		return [for (stage in stages) stage.name];
}
