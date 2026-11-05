#if !wasm
import runtime.memory.Arena;
#end
import runtime.memory.RawPtr;
import haxeon.reactive.Effect;
import haxeon.reactive.ReactiveRuntime;

struct SpecPoint {
	public var x:Int;
	public var y:Int;
	public function new(x:Int=0,y:Int=0) { this.x=x; this.y=y; }
}
struct SpecRect { public var point:SpecPoint; public function new() point=new SpecPoint(); }
class SpecNode {
	public var width:Int;
	public final id:Int=9;
	public function new(width:Int=0) this.width=width;
}
class SpecBase { public var base:Int=17; }
class SpecDerived extends SpecBase { public var own:Int=18; }
struct SpecOptionalRoot { public var part:Null<SpecPoint>; public function new() part=null; }
class SpecRoot {
	public var child:SpecNode;
	public var rect:SpecRect;
	public var optional:Null<SpecPoint>;
	public function new() { child=new SpecNode(); rect=new SpecRect(); optional=null; }
}
class SpecMissing { public var child:SpecNode; public function new() {} }
class SpecBox<T> { public var item:T; public function new(item:T) this.item=item; }
typedef SpecAlias=SpecNode;
class SpecBinding {
	public var path:WritableKeyPath<SpecNode,Int>;
	public var root:SpecNode;
	public function new(path:WritableKeyPath<SpecNode,Int>,root:SpecNode) { this.path=path; this.root=root; }
	public function update(value:Int):Void path.set(root,value);
	public function read():Int return path.get(root);
}
class SpecGrant {
	private var hidden:Int=41;
	public function new() {}
	public static function grant():WritableKeyPath<SpecGrant,Int> return \SpecGrant.hidden;
}
class SpecPointers {
	public static var calls:Int=0;
	public static function next(pointer:RawPtr<SpecPoint>):RawPtr<SpecPoint> { calls++; return pointer; }
	public static function foreign(address:hl.Bytes):Int {
		var pointer:RawPtr<SpecPoint>=address, path=pointPath(0);
		calls=0;
		pointer.store(new SpecPoint(1,2));
		path.set(next(pointer).ref,35);
		var stored=pointer.load();
		if(stored.x!=35 || stored.y!=2 || calls!=1) return 1;
		(\SpecPoint.y).set(pointer.ref,36);
		return path.get(pointer.ref)==35 && pointer.load().y==36 ? 42 : 2;
	}
}
class SpecEffects {
	public static var root:SpecRoot;
	public static var point:SpecPoint;
	public static var log:Int=0;
	public static var indices:Int=0;
	public static function path():WritableKeyPath<SpecRoot,Int> { log=log*10+1; return \SpecRoot.child.width; }
	public static function holder():SpecRoot { log=log*10+2; return root; }
	public static function value():Int { log=log*10+3; return 23; }
	public static function replaceChild():Int { root.child=new SpecNode(100); return 7; }
	public static function index():Int { indices++; return 0; }
	public static function changeSibling():Int { point.y=77; return 31; }
	public static function failValue():Int { log++; throw "value"; }
	public static function failAfterSibling():Int { point.y=99; throw "value"; }
}
struct SpecThrowPart implements Equatable {
	public var x:Int;
	public function new(x:Int) this.x=x;
	public function equals(other:SpecThrowPart):Bool { if(x==7 || other.x==7) throw "equals"; return x==other.x; }
}
class SpecThrowModel implements Observable {
	public var part:SpecThrowPart;
	public function new() part=new SpecThrowPart(0);
}
function opaqueWrite(path:WritableKeyPath<SpecRoot,Int>,root:SpecRoot):Void path.set(root,SpecEffects.replaceChild());
function pointPath(select:Int):WritableKeyPath<SpecPoint,Int> return select==0 ? \SpecPoint.x : \SpecPoint.y;
function optionalRootPath():WritableKeyPath<SpecOptionalRoot,Null<SpecPoint>> return \SpecOptionalRoot.part;
function optionalPath():WritableKeyPath<SpecRoot,Null<SpecPoint>> return \SpecRoot.optional;
function readGeneric<R,V>(path:KeyPath<R,V>,root:R):V return path.get(root);
function writeGeneric<R,V>(path:WritableKeyPath<R,V>,root:R,value:V):R { path.set(root,value); return root; }
function leftCompose(p:WritableKeyPath<SpecRoot,SpecRect>,q:WritableKeyPath<SpecRect,SpecPoint>,r:WritableKeyPath<SpecPoint,Int>):WritableKeyPath<SpecRoot,Int> return p.then(q).then(r);
function rightCompose(p:WritableKeyPath<SpecRoot,SpecRect>,q:WritableKeyPath<SpecRect,SpecPoint>,r:WritableKeyPath<SpecPoint,Int>):WritableKeyPath<SpecRoot,Int> return p.then(q.then(r));
function readableCompose(p:KeyPath<SpecRoot,SpecRect>,q:KeyPath<SpecRect,SpecPoint>,r:KeyPath<SpecPoint,Int>):KeyPath<SpecRoot,Int> return p.then(q).then(r);
function observedRead(p:KeyPath<SpecThrowModel,SpecThrowPart>,q:KeyPath<SpecThrowPart,Int>):KeyPath<SpecThrowModel,Int> return p.then(q);
function writeThrow(path:WritableKeyPath<SpecThrowModel,SpecThrowPart>,root:SpecThrowModel):Void path.set(root,new SpecThrowPart(7));
function main():Int {
	var root=new SpecRoot(); SpecEffects.root=root;
	var old=root.child;
	(\SpecRoot.child.width).set(root,SpecEffects.replaceChild());
	if(old.width!=7 || root.child.width!=100) return 1;
	root.child=new SpecNode(); old=root.child;
	opaqueWrite(\SpecRoot.child.width,root);
	if(old.width!=0 || root.child.width!=7) return 2;
	SpecEffects.log=0;
	SpecEffects.path().set(SpecEffects.holder(),SpecEffects.value());
	if(SpecEffects.log!=123 || root.child.width!=23) return 3;
	SpecEffects.log=0;
	if(SpecEffects.path().get(SpecEffects.holder())!=23 || SpecEffects.log!=12) return 4;
	var p=pointPath(0), points=[new SpecPoint(1,2),new SpecPoint(3,4)];
	SpecEffects.indices=0; SpecEffects.log=0;
	p.set(points[SpecEffects.index()],SpecEffects.value());
	if(SpecEffects.indices!=1 || SpecEffects.log!=3 || points[0].x!=23 || points[1].x!=3) return 5;
	SpecEffects.log=0;
	p.set(SpecEffects.holder().rect.point,SpecEffects.value());
	if(SpecEffects.log!=23 || root.rect.point.x!=23) return 6;
	SpecEffects.point=new SpecPoint(1,2);
	p.set(SpecEffects.point,SpecEffects.changeSibling());
	if(SpecEffects.point.x!=31 || SpecEffects.point.y!=77) return 7;
	var caught=false; SpecEffects.log=0;
	try p.set(SpecEffects.point,SpecEffects.failValue()) catch(_:Dynamic) caught=true;
	if(!caught || SpecEffects.log!=1 || SpecEffects.point.x!=31) return 8;
	caught=false;
	try p.set(SpecEffects.point,SpecEffects.failAfterSibling()) catch(_:Dynamic) caught=true;
	if(!caught || SpecEffects.point.x!=31 || SpecEffects.point.y!=99) return 9;
	var optional=optionalPath();
	if(optional.get(root)!=null) return 10;
	optional.set(root,new SpecPoint(41,5));
	var snapshot=optional.get(root);
	if(snapshot==null || snapshot.x!=41) return 11;
	snapshot.x=99;
	var retained=optional.get(root);
	if(retained==null || retained.x!=41) return 12;
	optional.set(root,null);
	if(optional.get(root)!=null || snapshot.x!=99) return 13;
	var left=leftCompose(\SpecRoot.rect,\SpecRect.point,\SpecPoint.x);
	var right=rightCompose(\SpecRoot.rect,\SpecRect.point,\SpecPoint.x);
	var readable=readableCompose(\SpecRoot.rect,\SpecRect.point,\SpecPoint.x);
	if(left!=right || left!=readable || left!=\SpecRoot.rect.point.x) return 14;
	if(haxeon.Hashing.hash(left)!=haxeon.Hashing.hash(readable)) return 15;
	if(left.toString()!="\\SpecRoot.rect.point.x") return 16;
	left.set(root,29);
	if(right.get(root)!=29 || readable.get(root)!=29) return 17;
	var paths:Map<KeyPath<SpecRoot,Int>,Int>=new Map();
	paths.set(readable,7);
	if(paths.get(left)!=7 || paths.get(\SpecRoot.rect.point.x)!=7) return 18;
	paths.set(right,8);
	if(paths.get(readable)!=8) return 19;
	var box=new SpecBox<SpecPoint>(new SpecPoint());
	(\SpecBox<SpecPoint>.item.x).set(box,30);
	var item=(\SpecBox<SpecPoint>.item).get(box); item.x=88;
	if(box.item.x!=30) return 20;
	var node=new SpecNode(), binding=new SpecBinding(\SpecNode.width,node);
	binding.update(32);
	if(binding.read()!=32 || readGeneric(\SpecAlias.width,node)!=32 || (\SpecNode.id).get(node)!=9) return 21;
	var updated=writeGeneric(p,new SpecPoint(),33);
	if(readGeneric(p,updated)!=33) return 22;
	var inherited=\SpecDerived.base;
	var derived=new SpecDerived();
	if(inherited.get(derived)!=17 || inherited.toString()!="\\SpecDerived.base") return 23;
	inherited.set(derived,19); if(derived.base!=19) return 23;
	var model=new SpecThrowModel(); caught=false;
	try writeThrow(\SpecThrowModel.part,model) catch(_:Dynamic) caught=true;
	var direct=new SpecThrowModel(), directCaught=false;
	try direct.part=new SpecThrowPart(7) catch(_:Dynamic) directCaught=true;
	if(!caught || !directCaught || model.part.x!=direct.part.x) return 24;
	#if !wasm
	var missing=new SpecMissing(), readCaught=false;
	directCaught=false;
	try SpecEffects.log=missing.child.width catch(_:Dynamic) directCaught=true;
	try SpecEffects.log=(\SpecMissing.child.width).get(missing) catch(_:Dynamic) readCaught=true;
	if(!directCaught || readCaught!=directCaught) return 25;
	#end
	var observed=new SpecThrowModel(), observedValue=0, runs=0;
	var read=observedRead(\SpecThrowModel.part,\SpecThrowPart.x);
	if(read!=\SpecThrowModel.part.x) return 26;
	var effect=new Effect(function() { observedValue=read.get(observed); runs++; });
	(\SpecThrowModel.part).set(observed,new SpecThrowPart(3));
	if(!effect.dirty) return 26;
	ReactiveRuntime.flushEffects();
	if(observedValue!=3 || runs!=2) return 26;
	effect.dispose();
	var optionalRoot=new SpecOptionalRoot(), optionalField=optionalRootPath();
	optionalField.set(optionalRoot,new SpecPoint(34));
	var present=optionalField.get(optionalRoot);
	if(present==null || present.x!=34) return 27;
	optionalField.set(optionalRoot,null);
	if(optionalField.get(optionalRoot)!=null) return 27;
	#if !wasm
	var arena=new Arena(64), pointer:RawPtr<SpecPoint>=arena.alloc(1);
	if(SpecPointers.foreign(pointer)!=42) return 28;
	arena.dispose();
	#end
	var granted=SpecGrant.grant(), first=new SpecGrant(), second=new SpecGrant();
	granted.set(first,38);
	if(granted.get(first)!=38 || granted.get(second)!=41) return 29;
	granted.set(second,39);
	if(granted.get(first)!=38 || granted.get(second)!=39) return 29;
	var captured=new SpecPoint(1,2);
	var update=function() p.set(captured,40);
	update();
	if(captured.x!=40 || captured.y!=2) return 30;
	return 42;
}

class SpecNullReads {
	static var root:SpecMissing;
	static var path:KeyPath<SpecMissing,Int>;
	public static function prepare():Void { root=new SpecMissing(); path=\SpecMissing.child.width; }
	public static function direct():Int return root.child.width;
	public static function known():Int return (\SpecMissing.child.width).get(root);
	public static function escaped():Int return path.get(root);
}
