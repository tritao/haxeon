import haxeon.reactive.Effect;
import haxeon.reactive.ReactiveRuntime;

struct PathObservedPoint implements Equatable {
	public var x:Int;
	public function new(x:Int) this.x=x;
}
class PathObserved implements Observable {
	public var count:Int=0;
	public var other:Int=0;
	public var point:PathObservedPoint=new PathObservedPoint(0);
}
function observePath(path:KeyPath<PathObserved,Int>, root:PathObserved):Int return path.get(root);
function updateObserved(path:WritableKeyPath<PathObserved,Int>, root:PathObserved, value:Int):Void path.set(root,value);
function replacePoint(path:WritableKeyPath<PathObserved,PathObservedPoint>, root:PathObserved, value:PathObservedPoint):Void path.set(root,value);
function main():Int {
	var model=new PathObserved(), last=0, runs=0;
	var effect=new Effect(function() { last=observePath(\PathObserved.count,model); runs++; });
	updateObserved(\PathObserved.other,model,7);
	if(effect.dirty) return 1;
	updateObserved(\PathObserved.count,model,21);
	if(!effect.dirty) return 2;
	ReactiveRuntime.flushEffects();
	if(last!=21 || runs!=2) return 3;
	updateObserved(\PathObserved.count,model,21);
	if(effect.dirty) return 4;
	(\PathObserved.count).set(model,22);
	if(!effect.dirty) return 5;
	ReactiveRuntime.flushEffects();
	if(last!=22 || runs!=3) return 6;
	var pointRuns=0;
	var pointEffect=new Effect(function() { var p=(\PathObserved.point).get(model); pointRuns+=p.x+1; });
	replacePoint(\PathObserved.point,model,new PathObservedPoint(3));
	if(!pointEffect.dirty) return 7;
	ReactiveRuntime.flushEffects();
	if(pointRuns!=5) return 8;
	effect.dispose(); pointEffect.dispose();
	return 42;
}
