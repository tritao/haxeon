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
 var source=new Signal<Int>(0), firstRuns=0, secondRuns=0, thirdRuns=0, fail=false, order="";
 var second=new Effect(function() { var value=source.value; secondRuns++; order += "B"; });
 var third=new Effect(function() { var value=source.value; thirdRuns++; order += "C"; if (fail) throw "second"; });
 var first=new Effect(function() { var value=source.value; firstRuns++; order += "A"; if (fail) throw "first"; });
 order="";
 fail=true; source.value=1;
 var caught:Dynamic=null;
 try ReactiveRuntime.flushEffects() catch (error:Dynamic) caught=error;
 if (caught!="first" || firstRuns!=2 || secondRuns!=2 || thirdRuns!=2 || order!="ACB"
     || ReactiveRuntime.lastFlushSuppressedErrors!=1) return 1;
 ReactiveRuntime.flushEffects();
 if (firstRuns!=2 || secondRuns!=2 || thirdRuns!=2 || order!="ACB") return 2;
 source.value=2; caught=null;
 try ReactiveRuntime.flushEffects() catch (error:Dynamic) caught=error;
 if (caught!="first" || firstRuns!=3 || secondRuns!=3 || thirdRuns!=3 || order!="ACBACB"
     || ReactiveRuntime.lastFlushSuppressedErrors!=1) return 3;
 fail=false; source.value=3; ReactiveRuntime.flushEffects();
 if (firstRuns!=4 || secondRuns!=4 || thirdRuns!=4 || order!="ACBACBACB"
     || ReactiveRuntime.lastFlushSuppressedErrors!=0) return 4;
 first.dispose(); second.dispose(); third.dispose();

 var input=new Signal<Int>(0), failValidation=false, observed=-1, derivedRuns=0;
 var derived=new Derived<Int>(function() {
  var value=input.value; derivedRuns++;
  if (failValidation) { failValidation=false; throw "validation"; }
  return value;
 });
 var reader=new Effect(function() observed=derived.value);
 failValidation=true; input.value=1;
 caught=null;
 try ReactiveRuntime.flushEffects() catch (error:Dynamic) caught=error;
 if (caught!="validation" || observed!=0 || derivedRuns!=2) return 5;
 ReactiveRuntime.flushEffects();
 if (observed!=0 || derivedRuns!=2) return 6;
 input.value=2; ReactiveRuntime.flushEffects();
 if (observed!=2 || derivedRuns!=3) return 7;
 reader.dispose(); derived.dispose();

 var disposableSource=new Signal<Int>(0), disposableRuns=0, disposableFail=false;
 var disposable=new Effect(function() { var value=disposableSource.value; disposableRuns++; if (disposableFail) throw "dispose"; });
 disposableFail=true; disposableSource.value=1;
 try ReactiveRuntime.flushEffects() catch (_:Dynamic) {}
 disposable.dispose(); disposableSource.value=2; ReactiveRuntime.flushEffects();
 if (disposableRuns!=2) return 8;

 var constructorRuns=0, constructorFail=true;
 try new Effect(function() { var value=source.value; constructorRuns++; if (constructorFail) { constructorFail=false; throw "first"; } }) catch (_:Dynamic) {}
 if (constructorRuns!=1) return 9;
 ReactiveRuntime.flushEffects();
 if (constructorRuns!=1) return 10;
 source.value=4; ReactiveRuntime.flushEffects();
 if (constructorRuns!=2) return 11;

 var partialA=new Signal<Int>(0), partialB=new Signal<Int>(0), partialFail=false, partialRuns=0;
 var partial=new Effect(function() { var a=partialA.value; partialRuns++; if (partialFail) throw "partial"; var b=partialB.value; });
 partialFail=true; partialA.value=1;
 try ReactiveRuntime.flushEffects() catch (_:Dynamic) {}
 partialB.value=1; ReactiveRuntime.flushEffects();
 if (partialRuns!=2) return 12;
 partialFail=false; partialA.value=2; ReactiveRuntime.flushEffects();
 if (partialRuns!=3) return 13;
 partial.dispose();

 var initialInput=new Signal<Int>(0), initialRuns=0, initialFail=true;
 var initialDerived=new Derived<Int>(function() { var value=initialInput.value; if (initialFail) throw "initial derived"; return value; });
 try new Effect(function() { var value=initialDerived.value; initialRuns++; }) catch (_:Dynamic) {}
 ReactiveRuntime.flushEffects();
 if (initialRuns!=0) return 14;
 initialFail=false; initialInput.value=1; ReactiveRuntime.flushEffects();
 if (initialRuns!=1) return 15;
 initialDerived.dispose();

 var model=new EffectFieldModel(), input2=new Signal<Int>(0), leftRuns=0, rightRuns=0;
 var parity=new Derived<Int>(function() return input2.value % 2);
 var leftReader=new Effect(function() { var left=model.left; var value=parity.value; leftRuns++; });
 var rightReader=new Effect(function() { var right=model.right; rightRuns++; });
 model.right=1; input2.value=2; ReactiveRuntime.flushEffects();
 if (leftRuns!=1 || rightRuns!=2) return 16;
 model.left=1; ReactiveRuntime.flushEffects();
 if (leftRuns!=2 || rightRuns!=2) return 17;
 leftReader.dispose(); rightReader.dispose(); parity.dispose();
 return 42;
}
