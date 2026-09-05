package compiler.modules;

import compiler.Diagnostic;
import compiler.abi.RuntimeAbi.RuntimeAbiDescriptor;
import compiler.hl.HlModuleAssembler;
import compiler.ir.Ir.IrObject;
import compiler.types.TypeRegistry;
import compiler.types.TypedAst.TypedProgram;

typedef CompilerSnapshot = {
	final modules:Map<String, ModuleState>;
	final types:TypeRegistry;
	final objectCache:Map<String, IrObject>;
	final lastTypedProgram:Null<TypedProgram>;
	final publishedAbi:Null<RuntimeAbiDescriptor>;
	final compiledOnce:Bool;
}

typedef PublishedBaseline = {
	final revision:Int;
	final abi:Null<RuntimeAbiDescriptor>;
}

typedef PendingPublication = {
	final baseline:PublishedBaseline;
	final revision:Int;
	final abi:RuntimeAbiDescriptor;
	final snapshot:CompilerSnapshot;
	final assembler:HlModuleAssembler;
}

typedef PublicationStatus = {
	final tracking:Bool;
	final acknowledgedRevision:Int;
	final pendingRevision:Null<Int>;
}

enum PublicationState {
	Untracked;
	Ready(baseline:PublishedBaseline);
	Pending(candidate:PendingPublication);
}

/** Owns valid compiler-to-runtime publication transitions and revision checks. */
class CompilerPublication {
	var state:PublicationState = Untracked;

	public function new() {}

	public function enable(?revision:Int = 0, ?abi:RuntimeAbiDescriptor):Void
		state = switch state {
			case Untracked: Ready({revision: revision, abi: abi});
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
		state = Ready({revision: revision, abi: candidate.abi});
	}

	public function reject(revision:Int):PendingPublication {
		var candidate = requirePending(revision);
		state = Ready(candidate.baseline);
		return candidate;
	}

	public function status():PublicationStatus
		return switch state {
			case Untracked: {tracking: false, acknowledgedRevision: 0, pendingRevision: null};
			case Ready(baseline): {tracking: true, acknowledgedRevision: baseline.revision, pendingRevision: null};
			case Pending(candidate): {
					tracking: true,
					acknowledgedRevision: candidate.baseline.revision,
					pendingRevision: candidate.revision
				};
		};

	public function baseline():Null<PublishedBaseline>
		return switch state {
			case Untracked: null;
			case Ready(baseline): baseline;
			case Pending(candidate): candidate.baseline;
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
