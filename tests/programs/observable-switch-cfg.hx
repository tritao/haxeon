class ObservableSwitchGesture {
	public var granularity:Int = 1;
	public function new() {}
	public function anchor(first:Int, last:Int):Void {}
}

class ObservableSwitchEditor implements Observable {
	final gesture = new ObservableSwitchGesture();
	public var selectionStart:Int = 0;
	public var selectionEnd:Int = 0;
	public function new() {}
	function select(value:Int):Bool {
		selectionStart = value;
		return true;
	}
	public function begin(clicks:Int, extend:Bool):Bool {
		gesture.granularity = extend ? 1 : clicks;
		var changed = switch gesture.granularity {
			case 2: select(2);
			case 3: select(3);
			case _: select(1);
		};
		gesture.anchor(selectionStart, selectionEnd);
		return changed;
	}
	public function branchCase():Int {
		return switch 2 {
			case this.selectionStart: 42;
			case _: 0;
		};
	}
	public function statement():Int {
		var result = 0;
		switch gesture.granularity {
			case this.selectionStart: result = 40;
			case _: result = 1;
		}
		return result;
	}
}

function main():Int {
	var editor = new ObservableSwitchEditor();
	if (!editor.begin(2, false) || editor.selectionStart != 2) return 1;
	return editor.branchCase() == 42 ? editor.statement() + editor.selectionStart : 0;
}
