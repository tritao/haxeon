package haxeon.ui.core;

/** Shared editor/terminal pointer policy; adapters own text boundaries and storage. */
class SelectionGesture {
 public var granularity:Int = 1;
 var key = "";
 var time = -1.0;
 var x = 0.0;
 var y = 0.0;
 var count = 0;
 var armed = false;
 var pending = false;
 var first = 0;
 var last = 0;
 public function new() {}
 static function finite(value:Float):Bool return value == value && value - value == 0;
 public function register(key:String, timestamp:Float, x:Float, y:Float):Int {
  if (!finite(timestamp) || !finite(x) || !finite(y)) { cancel(); return 1; }
  var dx=x-this.x, dy=y-this.y;
  var same=armed && key==this.key && time>=0 && timestamp>=time && timestamp-time<=0.5 && dx*dx+dy*dy<=36;
  count=same ? (count>=3 ? 1 : count+1) : 1;
  this.key=key; time=timestamp; this.x=x; this.y=y; armed=false; pending=true;
  return count;
 }
 public function complete(x:Float,y:Float):Void {
  if (!pending || !finite(x) || !finite(y) || moved(x,y)) { cancel(); return; }
  pending=false; armed=true;
 }
 function moved(x:Float,y:Float):Bool { var dx=x-this.x,dy=y-this.y;return dx*dx+dy*dy>36; }
 public function cancelIfMoved(x:Float,y:Float):Void { if(pending && moved(x,y)) cancel(); }
 public function cancel():Void { time=-1;key="";count=0;armed=false;pending=false; }
 public function anchor(first:Int,last:Int):Void { this.first=first;this.last=last; }
 public function extend(first:Int,last:Int):{anchor:Int,focus:Int}
  return first<this.first ? {anchor:this.last,focus:first} : {anchor:this.first,focus:last};
}
