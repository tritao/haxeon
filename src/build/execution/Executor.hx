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

	public function new(environment:BuildEnvironment, ?workerCount:Int = 1, ?print:String->Void) {
		this.environment = environment;
		this.workerCount = workerCount < 1 ? 1 : workerCount;
		this.print = print == null ? Sys.println : print;
		this.artifactCache = new ArtifactCache();
	}

	public function execute(plan:ExecutionPlan):ExecutionResult {
		digests = new ContentDigestCache();
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
			#if (target.threaded && !eval)
			var lock = new Lock(), waveMutex = new Mutex();
			for (action in wave) {
				var currentAction = action;
				var dependencyFingerprints = [
					for (dependency in currentAction.dependencies)
						fingerprints.get(dependency.key())
				];
				Thread.create(function() {
					// Always report and release: an exception escaping this thread would leave the
					// wave waiting on the lock forever.
					var result = try executeAction(currentAction,
						dependencyFingerprints) catch (error:Dynamic) new ActionResult(currentAction.id, 1, false, false, null, Std.string(error));
					waveMutex.acquire();
					waveResults.set(currentAction.id.key(), result);
					waveMutex.release();
					lock.release();
				});
			}
			for (_ in wave)
				lock.wait();
			#else
			var processActions:Array<{action:ExecutionAction, fingerprint:String}> = [],
				processTasks:Array<{
					command:String,
					arguments:Array<String>,
					cwd:String,
					environment:Map<String, String>
				}> = [];
			for (action in wave) {
				var dependencyFingerprints = [for (dependency in action.dependencies) fingerprints.get(dependency.key())];
				var fingerprint = ActionFingerprint.compute(action, environment.buildRoot, environment.target.toString(), dependencyFingerprints, digests);
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
			#end
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
		var fingerprint = preparedFingerprint == null ? ActionFingerprint.compute(action, environment.buildRoot, environment.target.toString(),
			dependencyFingerprints, digests) : preparedFingerprint;
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
