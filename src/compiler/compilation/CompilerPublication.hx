package compiler.compilation;

import compiler.Diagnostic;
import compiler.abi.RuntimeAbi.RuntimeAbiDescriptor;
import compiler.hl.incremental.HlModuleAssembler;
import compiler.ir.Ir.IrObject;
import compiler.modules.ModuleState;
import compiler.types.TypeRegistry;
import compiler.types.TypedAst.TypedProgram;
import compiler.semantic.SemanticProgram;

/** Compiler-owned semantic state captured before staging a publication. */
typedef CompilerSnapshot = {
	final modules:Map<String, ModuleState>;
	final types:TypeRegistry;
	final objectCache:Map<String, IrObject>;
	final lastTypedProgram:Null<TypedProgram>;
	final publishedAbi:Null<RuntimeAbiDescriptor>;
	final compiledOnce:Bool;
	final rehydrationBaseline:Null<Map<String, haxe.io.Bytes>>;
	final semanticProgram:Null<SemanticProgram>;
}

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
	final abi:RuntimeAbiDescriptor;
	final snapshot:CompilerSnapshot;
	final assembler:HlModuleAssembler;
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
	var state:PublicationState = Untracked;

	public function new() {}

	public function enable(?revision:Int = 0, ?abi:RuntimeAbiDescriptor, ?backendAvailable:Bool = false):Void
		state = switch state {
			case Untracked: Ready({revision: revision, abi: abi, backendAvailable: backendAvailable});
			case Ready(_): state;
			case Pending(_): throw "Cannot change publication tracking with a pending build";
		};

	public function beforeCompile():Void
		switch state {
			case Pending(candidate):
				throw 'Publication revision ${candidate.revision} is still pending';
			case Untracked, Ready(_):
		}

	public function candidate(revision:Int, abi:RuntimeAbiDescriptor, snapshot:CompilerSnapshot, assembler:HlModuleAssembler):Void
		state = switch state {
			case Untracked: Untracked;
			case Ready(baseline): Pending({
					baseline: baseline,
					revision: revision,
					abi: abi,
					snapshot: snapshot,
					assembler: assembler
				});
			case Pending(candidate): throw 'Publication revision ${candidate.revision} is still pending';
		};

	public function acknowledge(revision:Int):Void {
		var candidate = requirePending(revision);
		state = Ready({revision: revision, abi: candidate.abi, backendAvailable: true});
	}

	public function reject(revision:Int):PendingPublication {
		var candidate = requirePending(revision);
		state = Ready(candidate.baseline);
		return candidate;
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
			case Pending(candidate): throw 'Cannot persist pending publication revision ${candidate.revision}';
		};

	public function reconcile(runtimeRevision:Int):ReconnectDecision
		return switch state {
			case Untracked: ReloadDomain(PublicationTrackingDisabled);
			case Pending(candidate): ReloadDomain(PublicationPending(candidate.revision));
			case Ready(baseline):
				if (runtimeRevision != baseline.revision) ReloadDomain(RuntimeRevisionMismatch(runtimeRevision,
					baseline.revision)); else if (baseline.revision > 0 && !baseline.backendAvailable) ReloadDomain(BackendBaselineUnavailable); else
					ContinuePatching;
		};

	function requirePending(revision:Int):PendingPublication
		return switch state {
			case Untracked: throw "Publication tracking is not enabled";
			case Ready(_): throw "No publication is pending";
			case Pending(candidate):
				if (candidate.revision != revision)
					throw 'Publication revision mismatch: expected ${candidate.revision}, got $revision';
				candidate;
		};
}
