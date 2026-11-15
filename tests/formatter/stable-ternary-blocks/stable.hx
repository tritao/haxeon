class A {
	function new(?onUpdate:Float->Void, ?onComplete:Void->Void) {
		this.onUpdate = onUpdate == null ? function(_) {} : onUpdate;
		this.onComplete = onComplete == null ? function() {} : onComplete;
		var body = compute(function() {
			return 1;
		}) + 2;
	}
}
