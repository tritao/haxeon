package build.execution;

import build.execution.ActionResult.ExecutionResult;
import build.BuildEnvironment;
import build.execution.ExecutionAction.ActionKind;
#if (target.threaded && !eval)
import sys.thread.Lock;
import sys.thread.Mutex;
import sys.thread.Thread;
#end

/** Dependency-aware executor with a deterministic wavefront scheduler. */
class Executor implements ExecutionBackend {
	final environment:BuildEnvironment;
	final workerCount:Int;
	final print:String->Void;
	final artifactCache:ArtifactCache;
	var digests = new ContentDigestCache();

	/** Actions whose fingerprint another action consumes; see `fingerprintFor`. */
	var dependedOn:Map<String, Bool> = [];

	public function new(environment:BuildEnvironment, ?workerCount:Int = 1, ?print:String->Void) {
		this.environment = environment;
		this.workerCount = workerCount < 1 ? 1 : workerCount;
		this.print = print == null ? Sys.println : print;
		this.artifactCache = new ArtifactCache();
	}

	public function execute(plan:ExecutionPlan):ExecutionResult {
		digests = new ContentDigestCache();
		dependedOn = [];
		for (action in plan.actions)
			for (dependency in action.dependencies)
				dependedOn.set(dependency.key(), true);
		#if (target.threaded && !eval)
		return executeQueued(plan);
		#else
		return executeWaves(plan);
		#end
	}

	/** Single-threaded targets run ready actions in barrier-separated waves. */
	function executeWaves(plan:ExecutionPlan):ExecutionResult {
		var started = Sys.time() * 1000.0;
		var pending = new Map<String, ExecutionAction>(),
			completed = new Map<String, ActionResult>(),
			fingerprints = new Map<String, String>(),
			results:Array<ActionResult> = [];
		for (action in plan.actions)
			pending.set(action.id.key(), action);

		while (pending.iterator().hasNext()) {
			var propagated = true;
			while (propagated) {
				var newlyBlocked:Array<{action:ExecutionAction, failure:ActionResult}> = [];
				for (action in pending) {
					var failure = failedDependency(action, completed);
					if (failure != null)
						newlyBlocked.push({action: action, failure: failure});
				}
				newlyBlocked.sort((left, right) -> Reflect.compare(left.action.id.key(), right.action.id.key()));
				propagated = newlyBlocked.length > 0;
				for (blocked in newlyBlocked) {
					var result = new ActionResult(blocked.action.id, blocked.failure.exitCode, false, true, null,
						'Blocked by failed dependency ${blocked.failure.id}');
					completed.set(blocked.action.id.key(), result);
					results.push(result);
					pending.remove(blocked.action.id.key());
				}
			}
			var ready = [for (action in pending) if (dependenciesSucceeded(action, completed)) action];
			ready.sort((left, right) -> Reflect.compare(left.id.key(), right.id.key()));
			if (ready.length == 0 && pending.iterator().hasNext())
				throw "Execution plan has unresolved dependencies";
			if (ready.length == 0)
				break;
			var wave = ready.slice(0, workerCount),
				waveResults = new Map<String, ActionResult>();
			for (action in wave)
				print('[${action.id}] ${action.description}');
			var processActions:Array<{action:ExecutionAction, fingerprint:String}> = [],
				processTasks:Array<{
					command:String,
					arguments:Array<String>,
					cwd:String,
					environment:Map<String, String>
				}> = [];
			for (action in wave) {
				var dependencyFingerprints = [for (dependency in action.dependencies) fingerprints.get(dependency.key())];
				var fingerprint = fingerprintFor(action, dependencyFingerprints);
				if (isUpToDate(action, fingerprint, dependencyFingerprints)) {
					waveResults.set(action.id.key(), new ActionResult(action.id, 0, true, false, fingerprint));
					continue;
				}
				switch action.action {
					case Process(command, arguments, cwd, variables):
						try {
							ensureOutputDirectories(action);
							processTasks.push({
								command: command,
								arguments: arguments,
								cwd: cwd,
								environment: variables
							});
							processActions.push({action: action, fingerprint: fingerprint});
						} catch (error:Dynamic) {
							waveResults.set(action.id.key(), new ActionResult(action.id, 1, false, false, null, Std.string(error)));
						}
					case Compiler(_, _, _, _, _):
						waveResults.set(action.id.key(), executeAction(action, dependencyFingerprints, fingerprint, true));
				}
			}
			if (processTasks.length > 0) {
				var statuses:Array<Int>;
				try {
					statuses = ProcessRunner.runConcurrent(processTasks, workerCount, environment.buildRoot);
				} catch (error:Dynamic) {
					statuses = [for (_ in processTasks) 1];
					for (item in processActions)
						waveResults.set(item.action.id.key(), new ActionResult(item.action.id, 1, false, false, null, Std.string(error)));
				}
				for (index in 0...processActions.length) {
					var item = processActions[index];
					if (waveResults.exists(item.action.id.key()))
						continue;
					var status = statuses[index];
					try {
						if (status == 0 && isCacheable(item.action)) {
							ActionFingerprint.save(environment.buildRoot, item.action, item.fingerprint);
							if (ArtifactCache.isShareable(item.action))
								artifactCache.publish(item.action,
									ActionFingerprint.globalKey(item.action, environment.target.toString(),
										[for (dependency in item.action.dependencies) fingerprints.get(dependency.key())], digests));
						}
						waveResults.set(item.action.id.key(),
							new ActionResult(item.action.id, status, false, false, item.fingerprint, status == 0 ? null : 'Action exited with status $status'));
					} catch (error:Dynamic) {
						waveResults.set(item.action.id.key(), new ActionResult(item.action.id, 1, false, false, null, Std.string(error)));
					}
				}
			}
			for (action in wave) {
				var result = waveResults.get(action.id.key());
				completed.set(action.id.key(), result);
				results.push(result);
				pending.remove(action.id.key());
				if (result.fingerprint != null)
					fingerprints.set(action.id.key(), result.fingerprint);
				if (result.skipped)
					print('[${result.id}] clean (fingerprint match)');
				else if (!result.succeeded() && !result.blocked)
					print('[${result.id}] failed: ${result.message}');
			}
		}
		return new ExecutionResult(results, Sys.time() * 1000.0 - started);
	}

	/** Upper bound on simultaneous compiler actions, each of which holds a compiler heap. 0 means no limit. */
	public var maxConcurrentCompilers = 0;

	#if (target.threaded && !eval)
	/**
	 * Work-queue scheduler. Whenever a worker is free, the ready action on the longest remaining chain
	 * starts, so a slow action never idles the other workers behind a wave barrier.
	 */
	function executeQueued(plan:ExecutionPlan):ExecutionResult {
		var started = Sys.time() * 1000.0,
			pending = new Map<String, ExecutionAction>(),
			completed = new Map<String, ActionResult>(),
			fingerprints = new Map<String, String>(),
			results:Array<ActionResult> = [],
			depth = chainDepths(plan),
			finished:Array<{action:ExecutionAction, result:ActionResult}> = [],
			mutex = new Mutex(),
			signal = new Lock(),
			running = 0,
			runningCompilers = 0;
		for (action in plan.actions)
			pending.set(action.id.key(), action);

		while (pending.iterator().hasNext() || running > 0) {
			var propagated = true;
			while (propagated) {
				var newlyBlocked:Array<{action:ExecutionAction, failure:ActionResult}> = [];
				for (action in pending) {
					var failure = failedDependency(action, completed);
					if (failure != null)
						newlyBlocked.push({action: action, failure: failure});
				}
				newlyBlocked.sort((left, right) -> Reflect.compare(left.action.id.key(), right.action.id.key()));
				propagated = newlyBlocked.length > 0;
				for (blocked in newlyBlocked) {
					var result = new ActionResult(blocked.action.id, blocked.failure.exitCode, false, true, null,
						'Blocked by failed dependency ${blocked.failure.id}');
					completed.set(blocked.action.id.key(), result);
					results.push(result);
					pending.remove(blocked.action.id.key());
				}
			}
			var ready = [for (action in pending) if (dependenciesSucceeded(action, completed)) action];
			ready.sort((left, right) -> {
				var difference = depth.get(right.id.key()) - depth.get(left.id.key());
				return difference != 0 ? difference : Reflect.compare(left.id.key(), right.id.key());
			});
			for (action in ready) {
				if (running >= workerCount)
					break;
				var compiler = isCompiler(action);
				if (compiler && maxConcurrentCompilers > 0 && runningCompilers >= maxConcurrentCompilers)
					continue;
				pending.remove(action.id.key());
				running++;
				if (compiler)
					runningCompilers++;
				print('[${action.id}] ${action.description}');
				var currentAction = action, dependencyFingerprints = [for (dependency in action.dependencies) fingerprints.get(dependency.key())];
				Thread.create(function() {
					// Always report and release: an exception escaping this thread would leave the
					// scheduler waiting on the lock forever.
					var result = try executeAction(currentAction,
						dependencyFingerprints) catch (error:Dynamic) new ActionResult(currentAction.id, 1, false, false, null, Std.string(error));
					mutex.acquire();
					finished.push({action: currentAction, result: result});
					mutex.release();
					signal.release();
				});
			}
			if (running == 0) {
				if (pending.iterator().hasNext())
					throw "Execution plan has unresolved dependencies";
				break;
			}
			signal.wait();
			mutex.acquire();
			var batch = finished.splice(0, finished.length);
			mutex.release();
			// One release per finished action, but a batch may hold several: the surplus wakes are harmless.
			batch.sort((left, right) -> Reflect.compare(left.action.id.key(), right.action.id.key()));
			for (item in batch) {
				var result = item.result;
				running--;
				if (isCompiler(item.action))
					runningCompilers--;
				completed.set(item.action.id.key(), result);
				results.push(result);
				if (result.fingerprint != null)
					fingerprints.set(item.action.id.key(), result.fingerprint);
				if (result.skipped)
					print('[${result.id}] clean (fingerprint match)');
				else if (!result.succeeded() && !result.blocked)
					print('[${result.id}] failed: ${result.message}');
			}
		}
		return new ExecutionResult(results, Sys.time() * 1000.0 - started);
	}
	#end

	/** Length of the longest chain of dependents below each action, counting itself. */
	static function chainDepths(plan:ExecutionPlan):Map<String, Int> {
		var dependents = new Map<String, Array<String>>(), depth = new Map<String, Int>();
		for (action in plan.actions)
			for (dependency in action.dependencies) {
				var list = dependents.get(dependency.key());
				if (list == null) {
					list = [];
					dependents.set(dependency.key(), list);
				}
				list.push(action.id.key());
			}
		// `plan.actions` lists dependencies first, so walking it backwards sees every dependent before its dependency.
		var index = plan.actions.length;
		while (index > 0) {
			index--;
			var key = plan.actions[index].id.key(), longest = 0, list = dependents.get(key);
			if (list != null)
				for (dependent in list)
					if (depth.get(dependent) > longest)
						longest = depth.get(dependent);
			depth.set(key, longest + 1);
		}
		return depth;
	}

	static function isCompiler(action:ExecutionAction):Bool
		return switch action.action {
			case Compiler(_, _, _, _, _): true;
			case Process(_, _, _, _): false;
		};

	public function name():String
		return "native";

	function failedDependency(action:ExecutionAction, completed:Map<String, ActionResult>):Null<ActionResult> {
		for (dependency in action.dependencies) {
			var result = completed.get(dependency.key());
			if (result != null && !result.succeeded())
				return result;
		}
		return null;
	}

	function dependenciesSucceeded(action:ExecutionAction, completed:Map<String, ActionResult>):Bool {
		for (dependency in action.dependencies) {
			var result = completed.get(dependency.key());
			if (result == null || !result.succeeded())
				return false;
		}
		return true;
	}

	function executeAction(action:ExecutionAction, dependencyFingerprints:Array<String>, ?preparedFingerprint:String,
			freshnessChecked:Bool = false):ActionResult {
		var fingerprint = preparedFingerprint == null ? fingerprintFor(action, dependencyFingerprints) : preparedFingerprint;
		if (!freshnessChecked && isUpToDate(action, fingerprint, dependencyFingerprints))
			return new ActionResult(action.id, 0, true, false, fingerprint);
		try {
			ensureOutputDirectories(action);
			var status = switch action.action {
				case Process(command, arguments, cwd, variables):
					ProcessRunner.run(command, arguments, cwd, variables);
				case Compiler(_, _, _, _, invoke):
					invoke();
			};
			if (status == 0 && isCacheable(action)) {
				ActionFingerprint.save(environment.buildRoot, action, fingerprint);
				if (ArtifactCache.isShareable(action))
					artifactCache.publish(action, ActionFingerprint.globalKey(action, environment.target.toString(), dependencyFingerprints, digests));
			}
			return new ActionResult(action.id, status, false, false, fingerprint, status == 0 ? null : 'Action exited with status $status');
		} catch (error:Dynamic) {
			return new ActionResult(action.id, 1, false, false, null, Std.string(error));
		}
	}

	/**
	 * Fingerprints hash tool binaries and inputs, which is expensive (a 30 MB compiler takes ~25 s to
	 * hash under the Haxe interpreter). Only cacheable actions and actions others depend on use one;
	 * every other action always runs, so it gets none.
	 */
	function fingerprintFor(action:ExecutionAction, dependencyFingerprints:Array<String>):Null<String> {
		if (!isCacheable(action) && !dependedOn.exists(action.id.key()))
			return null;
		return ActionFingerprint.compute(action, environment.buildRoot, environment.target.toString(), dependencyFingerprints, digests);
	}

	function isUpToDate(action:ExecutionAction, fingerprint:String, dependencyFingerprints:Array<String>):Bool {
		if (!isCacheable(action))
			return false;
		if (ActionFingerprint.load(environment.buildRoot, action) == fingerprint && ActionFingerprint.outputsExist(action))
			return true;
		if (ArtifactCache.isShareable(action)
			&& artifactCache.restore(action, ActionFingerprint.globalKey(action, environment.target.toString(), dependencyFingerprints, digests))) {
			ActionFingerprint.save(environment.buildRoot, action, fingerprint);
			return true;
		}
		return false;
	}

	static function isCacheable(action:ExecutionAction):Bool
		return !action.alwaysRun && switch action.action {
			case Process(_, _, _, _): action.outputs.length > 0;
			case Compiler(_, _, _, _, _): action.outputs.length > 0;
		};

	static function ensureOutputDirectories(action:ExecutionAction):Void {
		for (output in action.outputs) {
			var directory = haxe.io.Path.directory(output);
			if (directory == "" || directory == "." || sys.FileSystem.exists(directory))
				continue;
			Directories.ensure(directory);
		}
	}
}
