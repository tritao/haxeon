enum ReflectedIntent {
	Selected(value:String);
}

enum AnonymousIntent {
	AnonymousSelected(value:String);
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

	var dynamicAnonymous:Dynamic = {child: {nested: {intent: AnonymousSelected("before")}}},
		child:Dynamic = Reflect.field(dynamicAnonymous, "child"),
		nested:Dynamic = Reflect.field(child, "nested");
	var anonymousBefore:AnonymousIntent = cast Reflect.field(nested, "intent");
	if (switch anonymousBefore { case AnonymousSelected("before"): false; default: true; }) return 8;
	Reflect.setField(nested, "intent", AnonymousSelected("after"));
	var anonymousAfter:AnonymousIntent = cast Reflect.field(nested, "intent");
	if (switch anonymousAfter { case AnonymousSelected("after"): false; default: true; }) return 9;
	var anonymousFields = Reflect.fields(nested);
	if (anonymousFields.length != 1 || anonymousFields[0] != "intent") return 10;
	return 42;
}
