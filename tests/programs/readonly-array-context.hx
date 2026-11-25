import haxe.ds.ReadOnlyArray;

typedef ContextVector = {
	final x:Float;
	final y:Float;
	final z:Float;
}
typedef ContextMotion = {
	final path:ReadOnlyArray<ContextVector>;
}

function main():Int {
	var motion:ContextMotion = {path: [{x: 0, y: 0, z: 0}, {x: 0, y: 10, z: 0}]};
	var values:Null<ReadOnlyArray<ContextVector>> = [for (i in 0...2) {
		x: i, y: 10, z: 0
	}];
	return motion.path[1].y == 10 && values[1].x == 1 ? 42 : 1;
}
