#if !wasm
import haxeon.reactive.ReactiveDependencySet;
import haxeon.reactive.ReactiveSource;
import haxeon.reactive.Signal;
import sys.thread.Lock;
import sys.thread.Thread;
function launch(sources:Array<ReactiveSource>, ready:Lock, go:Lock, done:Lock):Void {
 Thread.create(function() {
  ready.release(); go.wait();
  for (i in 0...2000) sources.push(new Signal<Int>(0));
  done.release();
 });
}
function main():Int {
 var lists:Array<Array<ReactiveSource>>=[], ready=new Lock(), go=new Lock(), done=new Lock();
 for (i in 0...8) { var list:Array<ReactiveSource>=[]; lists.push(list); launch(list,ready,go,done); }
 for (i in 0...8) ready.wait();
 for (i in 0...8) go.release();
 for (i in 0...8) done.wait();
 var sources:Array<ReactiveSource>=[];
 for (list in lists) for (source in list) sources.push(source);
 var reader=new ReactiveDependencySet();
 reader.setDependencies(sources,0,sources.length);
 if (reader.dependencyCount()!=16000) return 1;
 reader.setDependencies(sources,0,sources.length);
 if (reader.dependencyCount()!=16000) return 2;
 for (list in lists) {
  var signal:Signal<Int>=cast list[0];
  signal.value=1;
  if (!reader.dirty) return 3;
  reader.setDependencies(sources,0,sources.length);
 }
 reader.clearDependencies();
 return 42;
}
#else
function main():Int return 42;
#end
