enum TextIntent {
	Insert(text:String);
	Delete;
}

class CallbackOwner {
	public var callback:Null<(TextIntent, CallbackLayout)->Bool>;

	public function new() {}
}

struct CallbackLayout {
	public final number:Int;
	public final owner:CallbackOwner;

	public function new(number:Int, owner:CallbackOwner) {
		this.number = number;
		this.owner = owner;
	}
}

class CallbackField {
	public var onEdit:Null<(TextIntent, CallbackLayout)->Bool>;
	public var owner:CallbackOwner;

	public function new() {}
}

class Census {
	static var field:CallbackField;
	static var owners:Map<Int, CallbackField>;
	static var payload:String;
	static var handleText:String->Bool;

	@:expose public static function prepare():Void {
		payload = "retained text payload";
		field = new CallbackField();
		field.owner = new CallbackOwner();
		owners = new Map();
		owners.set(1, field);
		var dynamicField:Dynamic = field;
		var checkedField:CallbackField = cast dynamicField;
		if (checkedField != field) throw "Checked class cast changed a managed reference";
		field.onEdit = function(intent, layout) {
			return switch intent {
				case Insert(text): text == payload && layout.number == 42 && layout.owner == field.owner;
				case Delete: false;
			};
		};
		var escaped:Dynamic = Reflect.field(field, "onEdit");
		Reflect.setField(field, "onEdit", escaped);
		var wrong:(String, CallbackLayout)->Bool = function(_, _) return true;
		var rejected = false;
		try Reflect.setField(field, "onEdit", wrong) catch (_:Dynamic) rejected = true;
		if (!rejected) throw "Reflection accepted a closure with the wrong enum argument type";
		Reflect.setField(field, "onEdit", escaped);
		var layout = new CallbackLayout(42, field.owner);
		var delegateEdit = function(intent:TextIntent):Bool {
			var callback = field.onEdit;
			return callback != null && callback(intent, layout);
		};
		handleText = function(text:String):Bool {
			return delegateEdit(TextIntent.Insert(text));
		};
	}

	@:expose public static function run(count:Int):Int {
		var handler = handleText;
		if (field.onEdit == null || handler == null) return -1;
		var accepted = 0;
		for (_ in 0...count)
			if (handler(payload)) accepted++;
		return accepted;
	}
}

function main():Int {
	Census.prepare();
	return Census.run(128) == 128 ? 42 : 1;
}
