package build;

import build.Artifact.ArtifactKind;

/** Semantic artifact graph. No command lines or filesystem probes live here. */
class BuildPlan {
	public final requested:Array<ArtifactId>;
	public final artifacts:Array<Artifact>;

	final byKey:Map<String, Artifact>;

	public function new(requested:Array<ArtifactId>, artifacts:Array<Artifact>) {
		this.requested = requested.copy();
		this.requested.sort((a, b) -> Reflect.compare(a.key(), b.key()));
		this.artifacts = artifacts.copy();
		this.artifacts.sort((a, b) -> Reflect.compare(a.id.key(), b.id.key()));
		byKey = new Map();
		for (artifact in this.artifacts) {
			var key = artifact.id.key();
			if (byKey.exists(key))
				throw 'Duplicate artifact in build plan: $key';
			byKey.set(key, artifact);
		}
		for (artifact in this.artifacts)
			for (dependency in artifact.dependencies)
				if (!byKey.exists(dependency.key()))
					throw 'Artifact ${artifact.id} depends on missing artifact $dependency';
		for (artifact in this.requested)
			if (!byKey.exists(artifact.key()))
				throw 'Requested artifact is missing from build plan: $artifact';
		validateAcyclic();
	}

	public function artifact(id:ArtifactId):Null<Artifact>
		return byKey.get(id.key());

	public function toDebugString():String {
		var output = new StringBuf();
		output.add("Artifacts:\n");
		for (artifact in artifacts) {
			output.add('  ${artifact.id}\n');
			if (artifact.dependencies.length == 0) {
				output.add("    depends: none\n");
			} else {
				output.add("    depends:\n");
				for (dependency in artifact.dependencies)
					output.add('      $dependency\n');
			}
			var keys = [for (key in artifact.details.keys()) key];
			keys.sort(Reflect.compare);
			for (key in keys)
				output.add('    $key: ${artifact.details.get(key)}\n');
		}
		return output.toString();
	}

	function validateAcyclic():Void {
		var active = new Map<String, Bool>(),
			complete = new Map<String, Bool>();
		function visit(key:String):Void {
			if (complete.exists(key))
				return;
			if (active.exists(key))
				throw 'Build plan dependency cycle at $key';
			active.set(key, true);
			var artifact = byKey.get(key);
			for (dependency in artifact.dependencies)
				visit(dependency.key());
			active.remove(key);
			complete.set(key, true);
		}
		for (key in byKey.keys())
			visit(key);
	}
}
