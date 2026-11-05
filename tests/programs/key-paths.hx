class PathNode {
	public var width:Int;
	public var height:Int;
	public function new(value:Int) { width = value; height = value; }
}

struct PathPoint {
	public var x:Int;
	public var y:Int;
	public function new(value:Int) { x = value; y = value; }
}

function readNode(path:KeyPath<PathNode, Int>, node:PathNode):Int return path.get(node);
function writeNode(path:WritableKeyPath<PathNode, Int>, node:PathNode, value:Int):Void path.set(node, value);
function readPoint(path:KeyPath<PathPoint, Int>, point:PathPoint):Int return path.get(point);
function writePoint(path:WritableKeyPath<PathPoint, Int>, point:PathPoint, value:Int):PathPoint {
	path.set(point, value);
	return point;
}

class KeyPathCensus {
	static var node:PathNode;
	static var point:PathPoint;
	static var classPaths:Array<WritableKeyPath<PathNode, Int>>;
	static var rect:PathRect;
	static var composedPaths:Array<WritableKeyPath<PathRect, Int>>;
	static var structPaths:Array<WritableKeyPath<PathPoint, Int>>;

	public static function prepare():Void {
		node = new PathNode(0);
		point = new PathPoint(0);
		classPaths = [\PathNode.width, \PathNode.height];
		structPaths = [\PathPoint.x, \PathPoint.y];
		rect=new PathRect(0);
		composedPaths=[composeStruct(\PathRect.point, structPaths[0]), composeStruct(\PathRect.point, structPaths[1])];
	}

	public static function known(n:Int):Int {
		var current = new PathPoint(0);
		var sum = 0;
		var path = \PathPoint.x;
		for (i in 0...n) {
			genericSet(\PathNode.width,node,i);
			path.set(current, i);
			sum += (\PathNode.width).get(node) + genericRead(path,current);
		}
		return sum;
	}

	public static function escapedClass(n:Int):Int {
		var sum = 0;
		for (i in 0...n) {
			var path = classPaths[i & 1];
			path.set(node, i);
			sum += path.get(node);
		}
		return sum;
	}

	public static function escapedStruct(n:Int):Int {
		var current = new PathPoint(0);
		var sum = 0;
		for (i in 0...n) {
			var path = structPaths[i & 1];
			path.set(current, i);
			sum += path.get(current);
		}
		return sum;
	}

	public static function escapedComposition(n:Int):Int {
		var sum=0;
		for(i in 0...n) { var path=composedPaths[i&1]; path.set(rect,i); sum+=path.get(rect); }
		return sum;
	}

	public static function escapedStaticStruct(n:Int):Int {
		var sum = 0;
		for (i in 0...n) {
			var path = structPaths[i & 1];
			path.set(point, i);
			sum += path.get(point);
		}
		return sum;
	}
}

function main():Int {
	#if !wasm
	if(!allocationChecks()) return 20;
	#end
	var extra=extraChecks(); if(extra!=0) return extra;
	var node = new PathNode(0);
	writeNode(\PathNode.width, node, 21);
	var point = writePoint(\PathPoint.x, new PathPoint(0), 21);
	if (readNode(\PathNode.width, node) + readPoint(\PathPoint.x, point) != 42) return 0;
	KeyPathCensus.prepare();
	return KeyPathCensus.known(8) == 56 && KeyPathCensus.escapedClass(8) == 28 && KeyPathCensus.escapedStruct(8) == 28 ? 42 : 0;
}

class PathBase { public var base:Int=4; }
class PathDerived extends PathBase { public var own:Int=5; }
struct PathRect {
	public var point:PathPoint;
	public function new(value:Int) point=new PathPoint(value);
}
class PathHolder {
	public var point:PathPoint;
	public var node:PathNode;
	public final reference:PathNode;
	public function new() { point=new PathPoint(0); node=new PathNode(0); reference=new PathNode(0); }
}
function genericRead<R,V>(path:KeyPath<R,V>, root:R):V return path.get(root);
function composeClass(p:WritableKeyPath<PathHolder,PathNode>, q:WritableKeyPath<PathNode,Int>):WritableKeyPath<PathHolder,Int> return p.then(q);
function composeStruct(p:WritableKeyPath<PathRect,PathPoint>, q:WritableKeyPath<PathPoint,Int>):WritableKeyPath<PathRect,Int> return p.then(q);
function extraChecks():Int {
	var holder=new PathHolder(), rect=new PathRect(0);
	var known=(\PathRect.point).then(\PathPoint.x);
	known.set(rect,11);
	var escaped=composeStruct(\PathRect.point,\PathPoint.y);
	escaped.set(rect,12);
	if(rect.point.x!=11 || rect.point.y!=12) return 1;
	var classPath=composeClass(\PathHolder.node,\PathNode.width);
	classPath.set(holder,13);
	if(classPath.get(holder)!=13 || classPath!=\PathHolder.node.width) return 2;
	if(haxeon.Hashing.hash(classPath)!=haxeon.Hashing.hash(\PathHolder.node.width)) return 3;
	if(classPath.toString()!="\\PathHolder.node.width") return 4;
	(\PathHolder.reference.width).set(holder,14);
	if(holder.reference.width!=14) return 5;
	var inherited=\PathDerived.base;
	if(inherited.get(new PathDerived())!=4) return 6;
	if(genericRead(\PathRect.point.x,rect)!=11) return 7;
	var local=new PathPoint(0), path=\PathPoint.x;
	var update=function() { path.set(local,15); };
	update();
	if(local.x!=15) return 8;
	return 0;
}

#if !wasm
function allocationChecks():Bool {
	KeyPathCensus.prepare();
	var operations=[KeyPathCensus.known,KeyPathCensus.escapedClass,KeyPathCensus.escapedStruct,
		KeyPathCensus.escapedStaticStruct,KeyPathCensus.escapedComposition];
	var dump=Sys.getCwd()+"/out/key-paths-census.json";
	var index=0;
	for(operation in operations) {
		hl.Gc.censusStart(0);
		var result=operation(1024);
		hl.Gc.censusStop();
		hl.Gc.censusDump(dump);
		var census=haxe.Json.parse(sys.io.File.getContent(dump));
		sys.FileSystem.deleteFile(dump);
		if(census.allocations!=0 || result!=(index==0 ? 1047552 : 523776)) {
			Sys.println("Key path census mode "+index+": result="+result+", allocations="+census.allocations);
			return false;
		}
		index++;
	}
	return true;
}
#end

function genericSet<R,V>(path:WritableKeyPath<R,V>,root:R,value:V):Void path.set(root,value);
