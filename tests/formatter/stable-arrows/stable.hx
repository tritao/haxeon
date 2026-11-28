typedef Handler = Int->Void;
class A {
	final create:UiHostContext->UiApplication;
	var f:Int->Int = x -> x + 1;
	var g:(a:Int) -> Void;
	var list:Array<Int->Bool>;
	function new(cb:Void->Void, ?other:String->Int->Bool) {}
	function run() {
		items.map(item -> item.name);
		var o = {k: v -> v};
		call(function(x:Int->Int):Void {});
	}
}
// @lint:off function-lambda: the formatter is tested on the function form
