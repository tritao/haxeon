class Session implements Disposable {
	public function new() {
		Sys.println("open");
	}

	public function dispose():Void {
		Sys.println("close");
	}
}

function work():String {
	defer Sys.println("leave");
	scoped var session = new Session();
	defer Sys.println("finish");
	return "done";
}

function main():Void {
	Sys.println(work());
}
