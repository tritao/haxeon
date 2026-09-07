package editor;

private class ProfilerViewNode {
	public final id:String;
	public final parentId:Null<String>;
	public final stableKey:String;
	public final name:String;
	public final depth:Int;
	public var selfSamples = 0;
	public var totalSamples = 0;
	public final revisions = new Map<Int, Bool>();
	public final children:Array<String> = [];
	public var file:Null<String>;
	public var line:Null<Int>;
	public var locationRevision = 0;

	public function new(id:String, parentId:Null<String>, stableKey:String, name:String, depth:Int) {
		this.id = id;
		this.parentId = parentId;
		this.stableKey = stableKey;
		this.name = name;
		this.depth = depth;
	}
}

/** Incrementally turns cumulative profiler snapshots into editor call-tree and flame-graph state. */
class ProfilerViewModel {
	final nodes = new Map<String, ProfilerViewNode>();
	final roots:Array<String> = [];
	final stackSamples = new Map<String, Int>();
	var lastSamples = 0;

	public function new() {}

	public function reset():Void {
		nodes.clear();
		roots.resize(0);
		stackSamples.clear();
		lastSamples = 0;
	}

	public function update(snapshot:Dynamic):{state:Dynamic, delta:Dynamic} {
		var samples:Int = fieldInt(snapshot, "samples");
		if (samples < lastSamples) reset();
		lastSamples = samples;
		var changed = new Map<String, Bool>();
		for (stack in dynamicArray(snapshot, "stacks")) {
			var key:String = Reflect.field(stack, "key"), total:Int = fieldInt(stack, "samples"), previous = stackSamples.get(key);
			if (previous == null) previous = 0;
			var increment = total - previous;
			stackSamples.set(key, total);
			if (increment <= 0) continue;
			var parent:Null<String> = null, depth = 0, path = "", frames:Array<Dynamic> = Reflect.field(stack, "frameDetails");
			for (frame in frames) {
				var stableKey:String = Reflect.field(frame, "stableKey"), name:String = Reflect.field(frame, "name"), revision:Int = fieldInt(frame, "revision");
				path = path == "" ? stableKey : path + ">" + stableKey;
				var node = nodes.get(path);
				if (node == null) {
					node = new ProfilerViewNode(path, parent, stableKey, name, depth);
					nodes.set(path, node);
					if (parent == null) roots.push(path); else nodes.get(parent).children.push(path);
				}
				node.totalSamples += increment;
				node.revisions.set(revision, true);
				if (Reflect.field(frame, "file") != null && revision >= node.locationRevision) {
					node.file = Reflect.field(frame, "file");
					node.line = Reflect.field(frame, "line");
					node.locationRevision = revision;
				}
				changed.set(path, true);
				parent = path;
				depth++;
			}
			if (parent != null) nodes.get(parent).selfSamples += increment;
		}
		var flame = sortedNodes(), changedValues = [for (id in changed.keys()) nodeValue(nodes.get(id))];
		changedValues.sort(compareNodes);
		return {
			state: {
				callTree: [for (id in roots) treeValue(nodes.get(id))],
				flameGraph: flame,
				health: health(snapshot),
				revisionMarkers: dynamicArray(snapshot, "metadataChanges")
			},
			delta: {samples: samples, nodes: changedValues, health: health(snapshot), revisionMarkers: dynamicArray(snapshot, "metadataChanges")}
		};
	}

	function sortedNodes():Array<Dynamic> {
		var result = [for (node in nodes) nodeValue(node)];
		result.sort(compareNodes);
		return result;
	}

	function treeValue(node:ProfilerViewNode):Dynamic
		return {node: nodeValue(node), children: [for (id in node.children) treeValue(nodes.get(id))]};

	static function nodeValue(node:ProfilerViewNode):Dynamic {
		var revisions = [for (revision in node.revisions.keys()) revision];
		revisions.sort((a, b) -> a - b);
		return {id: node.id, parentId: node.parentId, stableKey: node.stableKey, name: node.name, depth: node.depth, file: node.file, line: node.line,
			selfSamples: node.selfSamples, totalSamples: node.totalSamples, revisions: revisions};
	}

	static function compareNodes(left:Dynamic, right:Dynamic):Int {
		var depth = fieldInt(left, "depth") - fieldInt(right, "depth");
		if (depth != 0) return depth;
		return Reflect.compare(Reflect.field(left, "id"), Reflect.field(right, "id"));
	}

	static function health(snapshot:Dynamic):Dynamic
		return {bufferCapacity: Reflect.field(snapshot, "bufferCapacity"), bufferUsed: Reflect.field(snapshot, "bufferUsed"),
			bufferUtilization: Reflect.field(snapshot, "bufferUtilization"), dropped: Reflect.field(snapshot, "dropped"),
			requestedSampleRate: Reflect.field(snapshot, "requestedSampleRate"), effectiveSampleRate: Reflect.field(snapshot, "effectiveSampleRate"),
			metadataRefreshMs: Reflect.field(snapshot, "metadataRefreshMs")};

	static function dynamicArray(value:Dynamic, field:String):Array<Dynamic> {
		var result:Dynamic = Reflect.field(value, field);
		return result == null ? [] : cast result;
	}

	static function fieldInt(value:Dynamic, field:String):Int {
		var result:Dynamic = Reflect.field(value, field);
		return result == null ? 0 : cast result;
	}
}
