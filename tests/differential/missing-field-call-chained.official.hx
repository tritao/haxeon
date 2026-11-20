// A missing method on the result of a call is reported at its own name, not at the call it follows.
class Node {
	public function new() {}

	public function next():Node
		return this;
}

class Main {
	static function main() {
		new Node().next().next().previous(1);
	}
}
