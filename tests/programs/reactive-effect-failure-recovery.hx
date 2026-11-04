import haxeon.reactive.Effect;
import haxeon.reactive.Derived;
import haxeon.reactive.ReactiveRuntime;
import haxeon.reactive.Signal;

class EffectFieldModel implements Observable {
 public var left:Int = 0;
 public var right:Int = 0;
 public function new() {}
}

function main():Int {
 var source=new Signal<Int>(0), firstRuns=0, secondRuns=0, fail=false, order="";
 var second=new Effect(function() { var value=source.value; secondRuns++; order += "B"; });
 var first=new Effect(function() { var value=source.value; firstRuns++; order += "A"; if (fail && value==1) { fail=false; throw "retry"; } });
 order="";
 fail=true; source.value=1;
 var caught=false;
 try ReactiveRuntime.flushEffects() catch (_:Dynamic) caught=true;
 if (!caught || firstRuns!=2 || secondRuns!=1 || order!="A") return 1;
 ReactiveRuntime.flushEffects();
 if (firstRuns!=3 || secondRuns!=2 || order!="ABA") return 2;
 source.value=2; ReactiveRuntime.flushEffects();
 if (firstRuns!=4 || secondRuns!=3) return 3;
 first.dispose(); second.dispose();
 var input=new Signal<Int>(0), failValidation=false, observed=-1, derivedRuns=0;
 var derived=new Derived<Int>(function() {
  var value=input.value; derivedRuns++;
  if (failValidation) { failValidation=false; throw "validation"; }
  return value;
 });
 var reader=new Effect(function() observed=derived.value);
 failValidation=true; input.value=1;
 caught=false;
 try ReactiveRuntime.flushEffects() catch (_:Dynamic) caught=true;
 if (!caught || observed!=0 || derivedRuns!=2) return 6;
 ReactiveRuntime.flushEffects();
 if (observed!=1 || derivedRuns!=3) return 7;
 reader.dispose(); derived.dispose();
 var disposableSource=new Signal<Int>(0), disposableRuns=0, disposableFail=false;
 var disposable=new Effect(function() { var value=disposableSource.value; disposableRuns++; if (disposableFail) throw "dispose"; });
 disposableFail=true; disposableSource.value=1;
 try ReactiveRuntime.flushEffects() catch (_:Dynamic) {}
 disposable.dispose();
 ReactiveRuntime.flushEffects();
 if (disposableRuns!=2) return 8;
 var constructorRuns=0, constructorFail=true;
 try new Effect(function() { var value=source.value; constructorRuns++; if (constructorFail) { constructorFail=false; throw "first"; } }) catch (_:Dynamic) {}
 if (constructorRuns!=1) return 4;
 ReactiveRuntime.flushEffects();
 if (constructorRuns!=2) return 5;
 var model=new EffectFieldModel(), input2=new Signal<Int>(0), leftRuns=0, rightRuns=0;
 var parity=new Derived<Int>(function() return input2.value % 2);
 var leftReader=new Effect(function() { var left=model.left; var value=parity.value; leftRuns++; });
 var rightReader=new Effect(function() { var right=model.right; rightRuns++; });
 model.right=1; input2.value=2; ReactiveRuntime.flushEffects();
 if (leftRuns!=1 || rightRuns!=2) return 9;
 model.left=1; ReactiveRuntime.flushEffects();
 if (leftRuns!=2 || rightRuns!=2) return 10;
 leftReader.dispose(); rightReader.dispose(); parity.dispose();
 return 42;
}
