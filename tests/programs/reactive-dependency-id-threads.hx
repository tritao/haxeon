#if !wasm
import haxeon.reactive.ReactiveSource;
import sys.thread.Lock;
import sys.thread.Thread;
function launch(ids:Array<haxe.Int64>, ready:Lock, go:Lock, done:Lock):Void {
 Thread.create(function() {
  ready.release(); go.wait();
  for (i in 0...20000) ids.push(new ReactiveSource().reactiveId);
  done.release();
 });
}
function main():Int {
 var lists:Array<Array<haxe.Int64>>=[], ready=new Lock(), go=new Lock(), done=new Lock();
 for (i in 0...8) { var list:Array<haxe.Int64>=[]; lists.push(list); launch(list,ready,go,done); }
 for (i in 0...8) ready.wait();
 for (i in 0...8) go.release();
 for (i in 0...8) done.wait();
 var seen:Map<haxe.Int64,Bool>=new Map();
 for (list in lists) for (id in list) { if (seen.exists(id)) return 1; seen.set(id,true); }
 return 42;
}

#else
function main():Int return 42;
#end
