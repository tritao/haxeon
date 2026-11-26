import compiler.ir.codec.IrFunctionStateEquality;
import compiler.ir.model.Ir.IrType;
import compiler.ir.model.IrBuilder;
import compiler.ir.model.IrFunction;
import compiler.ir.pipeline.IrFunctionIndex;
import compiler.ir.pipeline.IrFunctionPass;
import compiler.ir.pipeline.IrFunctionStages;
import compiler.ir.reuse.IrFactReader;
import compiler.ir.reuse.IrStageMemo.IrStageMemos;
import compiler.query.ComputedQueryKind;
import compiler.query.QueryDatabase;
import compiler.query.QuerySummary;

/**
 * What one per-function stage costs per function on a warm build, the stage driver (`IrFunctionStages.run`: a computed kind per
 * stage keyed by function symbol, its facts a kind of their own, `IrStageFacts`) against the bare engine loop (the same kind, its
 * whole-program step a summary over per-function contributions). See `docs/design/QUERY_ENGINE.md`, "Per-access costs", and `measure.py`,
 * which builds this with the checkout's compiler and counts main-thread instructions.
 *
 *     StageCostMain DRIVER CASE STAGES FUNCTIONS BUILDS
 *
 * DRIVER is `driver` or `engine`. CASE:
 *   held       every function held, the stage reads nothing but its input
 *   held1      held, each rewrite read one whole-program fact (driver: an `IrStageFacts` fact; engine: a summary key)
 *   held3      held, three facts each
 *   cutoff     every function rewritten (one fact it read changed) to a function equal to the one kept
 * DRIVER `access` measures one engine access per key instead (CASE: base, put, current, current2, contribute, holds,
 * recompute, has), each build doing what `base` does and then the access once per key; STAGES is ignored.
 * A cold build and a warm one run first; then it prints `ready`, waits for a line on standard input, runs BUILDS warm builds,
 * prints `done` and waits for another line, so that `measure.py` counts only the warm builds.
 */
class StageCostMain {
	static inline final FACT_KEYS = 64;

	static function main() {
		var args = Sys.args();
		if (args.length != 5) {
			Sys.println("usage: StageCostMain driver|engine|access CASE STAGES FUNCTIONS BUILDS");
			Sys.exit(2);
		}
		var driver = args[0],
			scenario = args[1],
			stages = Std.parseInt(args[2]) ?? 0,
			count = Std.parseInt(args[3]) ?? 0,
			builds = Std.parseInt(args[4]) ?? 0;
		var reads = switch scenario {
			case _ if (driver == "access"): 0;
			case "held": 0;
			case "held1": 1;
			case "held3": 3;
			case "cutoff": 1;
			case _: throw "unknown case " + scenario;
		}
		var cutoff = scenario == "cutoff";
		var functions = [for (index in 0...count) {
			var builder = new IrBuilder();
			builder.returnValue(builder.add(builder.constInt(index), builder.constInt(1)));
			new IrFunction("bench.F" + index + ".run", builder.arguments, IrType.I32, builder.blocks, Ordinary);
		}];
		var run:Int->Void = switch driver {
			case "driver": stageDriver(functions, stages, reads, cutoff);
			case "engine": engineDriver(functions, stages, reads, cutoff);
			case "access": accessDriver(functions, scenario);
			case _: throw "unknown driver " + driver;
		}
		run(0);
		run(1);
		Sys.println("ready");
		Sys.stdout().flush();
		Sys.stdin().readLine();
		for (build in 2...builds + 2)
			run(build);
		Sys.println("done");
		Sys.stdout().flush();
		Sys.stdin().readLine();
	}

	/** The stage driver: the input put into the session's database, then each stage run through its kind. */
	static function stageDriver(functions:Array<IrFunction>, stages:Int, reads:Int, cutoff:Bool):Int->Void {
		var database = new QueryDatabase();
		var memos = new IrStageMemos(database,
			database.register(new ComputedQueryKind<IrFunction>("ir-generation", IrFunctionStateEquality.same)));
		var names = [for (stage in 0...stages) "stage" + stage];
		var passes = [for (_ in 0...stages) new BenchPass(reads, cutoff)];
		return function(build:Int) {
			database.newRevision();
			var list = functions.copy();
			memos.startBuild(list, false);
			for (stage in 0...stages) {
				passes[stage].build = build;
				list = IrFunctionStages.run(names[stage], passes[stage], list, memos);
			}
		};
	}

	/**
	 * The engine's driver as slice 3 runs a stage: the contributions given to the stage's summary, then each function's memo
	 * verified, or computed with its reads recorded.
	 */
	static function engineDriver(functions:Array<IrFunction>, stages:Int, reads:Int, cutoff:Bool):Int->Void {
		var database = new QueryDatabase();
		var generation = database.register(new ComputedQueryKind<IrFunction>("ir-generation",
			IrFunctionStateEquality.same));
		var kinds = [for (stage in 0...stages)
			database.register(new ComputedQueryKind<IrFunction>("stage" + stage, IrFunctionStateEquality.same))];
		var summaries = [for (stage in 0...stages) database.register(new QuerySummary("stage" + stage + ":summary"))];
		var count = functions.length, keys = [for (fn in functions) fn.symbol.id];
		// What each function contributes: one key of the summary, the same array every build.
		var made:Array<Array<Int>> = [];
		for (index in 0...count)
			made.push([index % FACT_KEYS]);
		// One contributor beyond the functions names the key every rewrite reads in the cutoff case, every other build.
		var flipper = count + 1, flipKey = FACT_KEYS, flipped = [flipKey], none:Array<Int> = [];
		return function(build:Int) {
			database.newRevision();
			for (index in 0...count)
				generation.put(database, keys[index], functions[index]);
			var list = functions, output:Array<IrFunction> = [];
			for (stage in 0...stages) {
				var kind = kinds[stage], previous = stage == 0 ? generation : kinds[stage - 1];
				var summary = summaries[stage];
				if (reads > 0) {
					// Each contribution is made of the function alone: kept while the stage's input is.
					summary.open(database);
					for (index in 0...count) {
						var key = keys[index];
						if (!summary.holds(database, key, previous))
							summary.contribute(database, key, made[index]);
					}
					if (cutoff)
						summary.contribute(database, flipper, build % 2 == 0 ? flipped : none);
					summary.close(database);
				}
				output = [];
				output.resize(count);
				for (index in 0...count) {
					var key = keys[index], slot = kind.slotFor(key);
					if (kind.current(database, slot)) {
						output[index] = kind.value(slot);
						continue;
					}
					kind.begin(database, slot);
					var fn = previous.get(database, key), sum = 0;
					if (cutoff)
						summary.has(database, flipKey);
					else
						for (read in 0...reads)
							if (summary.has(database, (index + read) % FACT_KEYS))
								sum++;
					output[index] = kind.end(database, slot, cutoff ? fn.withBlocks(fn.blocks) : fn);
				}
				list = output;
			}
		};
	}

	/**
	 * One access per key and build, after the input is put (`base`, which puts each function again, the same object): `current`
	 * verifies a held key reading its input; `current2` one reading its input and a summary key; `contribute` gives a summary the
	 * contribution it holds; `holds` keeps it instead, as made of the input; `recompute` computes a key again to the value kept
	 * (begin, a read of the input, end); `has` reads a summary key in a frame.
	 */
	static function accessDriver(functions:Array<IrFunction>, access:String):Int->Void {
		var database = new QueryDatabase();
		var generation = database.register(new ComputedQueryKind<IrFunction>("ir-generation",
			IrFunctionStateEquality.same));
		var stage = database.register(new ComputedQueryKind<IrFunction>("stage", IrFunctionStateEquality.same));
		var summary = database.register(new QuerySummary("summary"));
		var count = functions.length, keys = [for (fn in functions) fn.symbol.id];
		var made:Array<Array<Int>> = [];
		for (index in 0...count)
			made.push([index % FACT_KEYS]);
		var reads = access == "current2" ? 1 : 0;
		return function(build:Int) {
			database.newRevision();
			for (index in 0...count)
				generation.put(database, keys[index], functions[index]);
			if (build == 0) {
				summary.open(database);
				for (index in 0...count)
					summary.contribute(database, keys[index], made[index]);
				summary.close(database);
				for (index in 0...count) {
					var key = keys[index], slot = stage.slotFor(key);
					stage.begin(database, slot);
					var fn = generation.get(database, key);
					if (reads > 0)
						summary.has(database, index % FACT_KEYS);
					stage.end(database, slot, fn);
				}
				return;
			}
			switch access {
				case "base":
				case "current" | "current2":
					for (index in 0...count) {
						var slot = stage.slotOf(keys[index]);
						if (!stage.current(database, slot) || stage.value(slot) == null)
							throw "not held";
					}
				case "contribute":
					summary.open(database);
					for (index in 0...count)
						summary.contribute(database, keys[index], made[index]);
					summary.close(database);
				case "holds":
					summary.open(database);
					for (index in 0...count)
						if (!summary.holds(database, keys[index], generation))
							throw "not held";
					summary.close(database);
				case "recompute":
					for (index in 0...count) {
						var key = keys[index], slot = stage.slotOf(key);
						stage.begin(database, slot);
						stage.end(database, slot, generation.get(database, key));
					}
				case "has":
					database.beginRecording();
					for (index in 0...count)
						summary.has(database, index % FACT_KEYS);
					database.endRecording();
				case _:
					throw "unknown access " + access;
			}
		};
	}
}

/** A stage that leaves each function alone (or, in the cutoff case, makes an equal copy), reading `reads` facts per rewrite. */
class BenchPass extends IrFunctionPass {
	final reads:Int;
	final cutoff:Bool;
	final keys = [for (index in 0...65) "fact" + index];
	final counts:Array<Int> = [];

	public var build = 0;

	public function new(reads:Int, cutoff:Bool) {
		this.reads = reads;
		this.cutoff = cutoff;
	}

	override public function summarize(fn:IrFunction):Int
		return fn.symbol.id % 64;

	override public function prepare(functions:Array<IrFunction>, summaries:Array<Int>, names:IrFunctionIndex):Void {
		if (reads == 0)
			return;
		counts.resize(0);
		for (_ in 0...64)
			counts.push(0);
		for (summary in summaries)
			counts[summary]++;
	}

	override public function transform(fn:IrFunction, summary:Int, reader:IrFactReader):IrFunction {
		if (cutoff) {
			reader.read(0, keys[64]);
			return fn.withBlocks(fn.blocks);
		}
		for (read in 0...reads)
			reader.read(0, keys[(fn.symbol.id + read) % 64]);
		return fn;
	}

	override public function fact(kind:Int, key:String):Int
		return key == keys[64] ? build % 2 : counts[Std.parseInt(key.substr(4)) ?? 0];

	override public function finish(functions:Array<IrFunction>):Array<IrFunction>
		return functions;
}
