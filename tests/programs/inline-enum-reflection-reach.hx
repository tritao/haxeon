enum ReflectedIntent {
	Selected(value:String);
}

class ReflectedLeaf {
	public var intent:ReflectedIntent;
	public var next:Null<ReflectedLeaf>;

	public function new(value:String) {
		intent = Selected(value);
		next = null;
	}
}

class ReflectedRoot {
	public var branch:ReflectedLeaf;
	public var items:Array<ReflectedLeaf>;
	public var byId:Map<String, ReflectedLeaf>;
	public var create:Void->ReflectedLeaf;

	public function new() {
		branch = new ReflectedLeaf("before");
		items = [branch];
		byId = new Map();
		byId.set("branch", branch);
		create = function() return branch;
	}
}

function checkLeaf(value:Dynamic, expected:String):Bool {
	if (value == null) return false;
	var intent:ReflectedIntent = cast Reflect.field(value, "intent");
	return switch intent {
		case Selected(text): text == expected;
	};
}

function main():Int {
	var root:Dynamic = new ReflectedRoot(), leaf:Dynamic = Reflect.field(root, "branch");
	if (!checkLeaf(leaf, "before")) return 1;
	Reflect.setField(leaf, "intent", Selected("after"));
	if (!checkLeaf(leaf, "after")) return 2;

	var rootFields = Reflect.fields(root);
	rootFields.sort(Reflect.compare);
	if (rootFields.join(",") != "branch,byId,create,items") return 3;

	var reflectedFields = Reflect.fields(leaf);
	reflectedFields.sort(Reflect.compare);
	if (reflectedFields.join(",") != "intent,next") return 4;

	var items:Array<ReflectedLeaf> = cast Reflect.field(root, "items"),
		byId:Map<String, ReflectedLeaf> = cast Reflect.field(root, "byId"),
		create:Void->ReflectedLeaf = cast Reflect.field(root, "create");
	if (!checkLeaf(items[0], "after")) return 5;
	if (!checkLeaf(byId.get("branch"), "after")) return 6;
	if (!checkLeaf(create(), "after")) return 7;
	return 42;
}
