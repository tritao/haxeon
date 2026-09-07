import editor.ProfilerViewModel;

class ProfilerViewModelMain {
	static function require(condition:Bool, message:String):Void {
		if (!condition) throw message;
	}

	static function main():Void {
		var model = new ProfilerViewModel();
		var first = model.update(snapshot(3, [stack("r1", 3, 1)]));
		require(first.state.flameGraph.length == 2, "expected root and leaf flame nodes");
		require(first.state.callTree.length == 1 && first.state.callTree[0].children.length == 1, "expected a nested call tree");
		require(first.delta.nodes.length == 2, "initial delta omitted nodes");

		var second = model.update(snapshot(5, [stack("r1", 3, 1), stack("r2", 2, 2)]));
		var leaf = second.state.flameGraph[1];
		require(leaf.totalSamples == 5 && leaf.selfSamples == 5, "stable nodes did not merge cumulative revisions");
		require(leaf.revisions.length == 2 && leaf.revisions[0] == 1 && leaf.revisions[1] == 2, "revision detail was lost");
		require(leaf.file == "Work.hx" && leaf.line == 2, "latest revision source location was not retained");
		require(second.delta.nodes.length == 2 && second.delta.nodes[1].totalSamples == 5, "incremental delta was incorrect");
		require(second.state.health.effectiveSampleRate == 125 && second.state.revisionMarkers.length == 1, "health or revision markers missing");

		var reset = model.update(snapshot(0, []));
		require(reset.state.flameGraph.length == 0 && reset.state.callTree.length == 0, "sample reset retained stale nodes");
		Sys.println("PASS: profiler view model incrementally merges revisions");
	}

	static function stack(key:String, samples:Int, revision:Int):Dynamic
		return {key: key, samples: samples, frameDetails: [
			{key: '1:$revision:10', stableKey: "1:10", name: "Main.main", revision: revision},
			{key: '1:$revision:11', stableKey: "1:11", name: "Work.work", revision: revision, file: "Work.hx", line: revision}
		]};

	static function snapshot(samples:Int, stacks:Array<Dynamic>):Dynamic
		return {samples: samples, stacks: stacks, bufferCapacity: "8388608", bufferUsed: "1024", bufferUtilization: 0.01, dropped: "0",
			requestedSampleRate: 250, effectiveSampleRate: 125, metadataRefreshMs: 0.4,
			metadataChanges: samples == 5 ? [{timestamp: 2.0, moduleId: "1", oldRevision: 1, newRevision: 2}] : []};
}
