class Project {
	public var joints:Null<Array<String>> = null;
	public var weights:Null<Map<String, Int>> = null;

	public function new() {}
}

// An empty literal in either branch takes its element type from the other branch.
function main():Int {
	var project = new Project();
	var first = project.joints == null ? [] : project.joints.copy();
	first.push("x");
	project.joints = ["y", "z"];
	var second = project.joints == null ? [] : project.joints.copy();
	var third = project.joints != null ? project.joints.copy() : [];
	var weights = project.weights == null ? [] : project.weights;
	weights.set("k", 1);
	return first.length == 1 && second.length == 2 && third.length == 2 && weights.get("k") == 1 ? 42 : 1;
}
