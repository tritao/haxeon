enum DirectIntent {
	Value(value:Int);
}

class DirectLeaf {
	public var intent:DirectIntent;
	public function new() intent = Value(1);
}

enum ArrayIntent {
	Value(value:Int);
}

class ArrayLeaf {
	public var intent:ArrayIntent;
	public function new() intent = Value(2);
}

enum MapIntent {
	Value(value:Int);
}

class MapLeaf {
	public var intent:MapIntent;
	public function new() intent = Value(3);
}

enum ClosureIntent {
	Value(value:Int);
}

class ClosureLeaf {
	public var intent:ClosureIntent;
	public function new() intent = Value(4);
}

class DynamicRoot {
	public var branch:DirectLeaf;
	public var items:Array<ArrayLeaf>;
	public var byId:Map<String, MapLeaf>;
	public var update:Void->Bool;

	public function new() {
		branch = new DirectLeaf();
		items = [new ArrayLeaf()];
		byId = new Map();
		byId.set("entry", new MapLeaf());
		var captured = new ClosureLeaf();
		update = function() {
			switch captured.intent {
				case Value(_): captured.intent = Value(5);
			}
			return true;
		};
	}
}

function isDirect(value:DirectIntent):Bool return switch value { case Value(1): true; default: false; };
function isArray(value:ArrayIntent):Bool return switch value { case Value(2): true; default: false; };
function isMap(value:MapIntent):Bool return switch value { case Value(3): true; default: false; };

function main():Int {
	var dynamic:Dynamic = new DynamicRoot(), root:DynamicRoot = cast dynamic;
	var mapLeaf = root.byId.get("entry");
	if (mapLeaf == null || !isDirect(root.branch.intent) || !isArray(root.items[0].intent) || !isMap(mapLeaf.intent)) return 1;
	if (!root.update()) return 2;
	return 42;
}
