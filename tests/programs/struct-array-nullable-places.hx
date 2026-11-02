struct P { public var x:Int; public function new(x:Int) this.x=x; public function bump():Void x++; }
struct N { public var value:P; public function new(x:Int) value=new P(x); }
function grow(values:Array<Null<P>>):Int { for(i in 0...64) values.push(new P(i)); return 2; }
function clear(values:Array<Null<P>>):Int { values[0]=null; return 5; }
function main():Int {
 var values:Array<Null<P>>=[new P(10)];
 if(values[0]!=null) values[0].x += grow(values);
 var copy=values[0]; if(copy==null || copy.x!=12 || values.length!=65) return 1;
 var threw=false;
 try { if(values[0]!=null) values[0].x = clear(values); } catch(e:Dynamic) { threw=true; }
 if(!threw || values[0]!=null) return 2;
	var nested:Array<Null<N>> = [new N(10), null];
	if(nested[0]!=null) nested[0].value.x += 2;
	if(nested[0]!=null) nested[0].value.bump();
	if(nested[0]!=null) { var old = nested[0].value.x++; if(old!=13) return 3; }
	if(nested[0]!=null) nested[0].value.x=17;
	var result=nested[0];
	if(result==null || result.value.x!=17 || nested[1]!=null) return 4;
 return 42;
}
