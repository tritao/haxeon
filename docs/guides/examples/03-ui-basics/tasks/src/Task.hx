/** One task: what the list shows and the detail edits. */
class Task {
	public var title:String;
	public var done:Bool;

	public function new(title:String) {
		this.title = title;
		done = false;
	}
}
