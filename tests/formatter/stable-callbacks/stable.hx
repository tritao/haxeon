class A {
	function run() {
		call(function(x:Int->Int):Void {});
		list.sort((a, b) -> {
			return a - b;
		});
		var xs = [for (i in 0...3) {
			i;
		}];
		var mk = x -> {y: x};
		timer(function() {
			tick();
		}, 10);
	}
}
