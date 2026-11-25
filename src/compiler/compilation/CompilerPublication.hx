package compiler.compilation;

import compiler.abi.RuntimeAbi.RuntimeAbiDescriptor;
import compiler.core.InternalError;

/** Runtime revision and ABI last acknowledged by the host. */
typedef PublishedBaseline = {
	final revision:Int;
	final abi:Null<RuntimeAbiDescriptor>;
	final backendAvailable:Bool;
}

/** Candidate build retained until the host acknowledges or rejects it. */
typedef PendingPublication = {
	final baseline:PublishedBaseline;
	final revision:Int;
	final abi:Null<RuntimeAbiDescriptor>;
	/** The state the build started from, which rejecting or retracting the publication returns to. */
	final snapshot:SessionState;
}

/** Read-only summary of the current publication state machine. */
typedef PublicationStatus = {
	final tracking:Bool;
	final acknowledgedRevision:Int;
	final hasPendingRevision:Bool;
	final pendingRevision:Int;
}

/** Minimal acknowledged publication state stored across compiler sessions. */
typedef PublicationPersistence = {
	final tracking:Bool;
	final revision:Int;
	final abi:Null<RuntimeAbiDescriptor>;
}

/** Internal states of the compiler-to-runtime publication transaction. */
enum PublicationState {
	Untracked;
	Ready(baseline:PublishedBaseline);
	Pending(candidate:PendingPublication);
}

/** Action required after comparing a reconnecting runtime with compiler state. */
enum ReconnectDecision {
	ContinuePatching;
	ReloadDomain(reason:ReconnectReason);
}

/** Stable reason that incremental patching cannot safely resume. */
enum ReconnectReason {
	PublicationTrackingDisabled;
	PublicationPending(revision:Int);
	RuntimeRevisionMismatch(runtimeRevision:Int, acknowledgedRevision:Int);
	BackendBaselineUnavailable;
	ModuleIdentityMismatch;
}

/** Owns valid compiler-to-runtime publication transitions and revision checks. */
class CompilerPublication {
	/** How many acknowledged publications can be taken back (`retract`); each holds a snapshot and an assembler. */
	public static inline final RETRACTABLE:Int = 3;

	var state:PublicationState = Untracked;

	/** Acknowledged publications, oldest first, each with the state it was built from. */
	var acknowledged:Array<PendingPublication> = [];

	public function new() {}

	public function enable(?revision:Int = 0, ?abi:RuntimeAbiDescriptor, ?backendAvailable:Bool = false):Void
		state = switch state {
			case Untracked: Ready({revision: revision, abi: abi, backendAvailable: backendAvailable});
			case Ready(_): state;
			case Pending(_): throw new InternalError("Cannot change publication tracking with a pending build");
		};

	public function beforeCompile():Void
		switch state {
			case Pending(candidate):
				throw new InternalError('Publication revision ${candidate.revision} is still pending');
			case Untracked, Ready(_):
		}

	/** `abi` is null for a build that keeps no session (`BackendAssemblyResult.abi`). */
	public function candidate(revision:Int, abi:Null<RuntimeAbiDescriptor>, snapshot:SessionState):Void {
		switch state {
			case Untracked:
			case Ready(baseline):
				state = Pending({
					baseline: baseline,
					revision: revision,
					abi: abi,
					snapshot: snapshot
				});
			case Pending(candidate):
				throw new InternalError('Publication revision ${candidate.revision} is still pending');
		}
	}

	/** A no-op build needs no host action and must not create an acknowledgement opportunity. */
	public function unchanged(revision:Int):Void
		switch state {
			case Untracked:
			case Ready(baseline):
				if (revision != baseline.revision)
					throw new InternalError('Unchanged publication revision mismatch: expected ${baseline.revision}, got $revision');
			case Pending(candidate):
				throw new InternalError('Publication revision ${candidate.revision} is still pending');
		}

	/**
	 * `retractable` keeps the publication, with the state it was built from, to be taken back (`retract`): only a live host can
	 * refuse one, so a build that publishes to none keeps no history, and drops what live builds kept.
	 */
	public function acknowledge(revision:Int, retractable:Bool):Void {
		var candidate = requirePending(revision);
		state = Ready({revision: revision, abi: candidate.abi, backendAvailable: true});
		if (!retractable) {
			acknowledged.resize(0);
			return;
		}
		acknowledged.push(candidate);
		if (acknowledged.length > RETRACTABLE)
			acknowledged.shift();
	}

	/**
	 * Takes back the acknowledged publications after `revision`, which the host still runs because it refused them (`haxeon
	 * run --watch --strict-live` does not reload). Returns the publication that was built on `revision`, whose snapshot
	 * and assembler describe it, or null when it is not among the last few or a newer build is pending.
	 */
	public function retract(revision:Int):Null<PendingPublication> {
		switch state {
			case Ready(_):
			case Untracked, Pending(_):
				return null;
		}
		var index = acknowledged.length - 1;
		while (index >= 0 && acknowledged[index].baseline.revision != revision)
			index--;
		if (index < 0)
			return null;
		var candidate = acknowledged[index];
		acknowledged.splice(index, acknowledged.length - index);
		state = Ready(candidate.baseline);
		return candidate;
	}

	public function reject(revision:Int):PendingPublication {
		var candidate = requirePending(revision);
		state = Ready(candidate.baseline);
		return candidate;
	}

	/** The oldest state a rejection or a retraction can return to, or null for none. */
	public function oldestSnapshot():Null<SessionState> {
		if (acknowledged.length > 0)
			return acknowledged[0].snapshot;
		return switch state {
			case Pending(candidate): candidate.snapshot;
			case Untracked, Ready(_): null;
		};
	}

	public function status():PublicationStatus
		return switch state {
			case Untracked: {
				tracking: false,
				acknowledgedRevision: 0,
				hasPendingRevision: false,
				pendingRevision: 0
			};
			case Ready(baseline): {
				tracking: true,
				acknowledgedRevision: baseline.revision,
				hasPendingRevision: false,
				pendingRevision: 0
			};
			case Pending(candidate): {
				tracking: true,
				acknowledgedRevision: candidate.baseline.revision,
				hasPendingRevision: true,
				pendingRevision: candidate.revision
			};
		};

	public function baseline():Null<PublishedBaseline>
		return switch state {
			case Untracked: null;
			case Ready(baseline): baseline;
			case Pending(candidate): candidate.baseline;
		};

	public function persistence():PublicationPersistence
		return switch state {
			case Untracked: {tracking: false, revision: 0, abi: null};
			case Ready(baseline): {tracking: true, revision: baseline.revision, abi: baseline.abi};
			case Pending(candidate): throw new InternalError('Cannot persist pending publication revision ${candidate.revision}');
		};

	public function reconcile(runtimeRevision:Int):ReconnectDecision
		return switch state {
			case Untracked: ReloadDomain(PublicationTrackingDisabled);
			case Pending(candidate): ReloadDomain(PublicationPending(candidate.revision));
			case Ready(baseline):
				if (runtimeRevision != baseline.revision) ReloadDomain(RuntimeRevisionMismatch(runtimeRevision,
					baseline.revision));
				else if (baseline.revision > 0 && !baseline.backendAvailable) ReloadDomain(BackendBaselineUnavailable);
				else
					ContinuePatching;
		};

	function requirePending(revision:Int):PendingPublication
		return switch state {
			case Untracked: throw new InternalError("Publication tracking is not enabled");
			case Ready(_): throw new InternalError("No publication is pending");
			case Pending(candidate):
				if (candidate.revision != revision)
					throw new InternalError('Publication revision mismatch: expected ${candidate.revision}, got $revision');
				candidate;
		};
}
