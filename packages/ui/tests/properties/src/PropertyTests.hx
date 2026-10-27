import haxeon.ui.core.*;
import haxeon.ui.editing.EditorDocument;
import haxeon.ui.properties.*;
import haxeon.ui.widgets.properties.PropertyEditor;

class PropertyTests {
	static function check(value:Bool, message:String):Void { if (!value) throw message; }
	static function rejected(result:PropertyEditResult):Bool return switch result { case Rejected(_): true; default: false; };
	public static function main():Int {
		try {
			var value = 1;
			var writes = 0;
			var submissions = 0;
			var ticket = new PropertyPendingEdit();
			var options = new PropertyDescriptorOptions(); options.minimum = 0; options.maximum = 10;
			options.commit = (_, next, _) -> { submissions++; return Pending(ticket); };
			var descriptor = new PropertyDescriptor("size", "Size", PropertyType.Int,
				_ -> PropertyValue.Int(value), (_, _) -> { writes++; }, options);
			var document = new EditorDocument("external");
			var commands = new CommandContext(document);
			var events:Array<String> = []; commands.onPropertyEdit = event -> events.push(event.result);
			var binding = new PropertyBinding(descriptor, commands);
			check(rejected(binding.apply(PropertyValue.Int(11))) && submissions == 0, "Validation precedes submission");
			check(binding.apply(PropertyValue.Int(1)) == Unchanged && submissions == 0, "Equality precedes submission");
			events.resize(0);
			var result = binding.apply(PropertyValue.Int(2));
			check(switch result { case Pending(edit): edit == ticket; default: false; }, "Submission is pending");
			check(value == 1 && writes == 0 && document.history.undoCount == 0, "External transaction does not mutate UI history");
			ticket.resolve(Rejected("Evaluation failed"));
			check(events.length == 2 && events[1] == "Rejected(Evaluation failed)", "Observer sees eventual failure");
			var late = 0; ticket.onComplete(_ -> { late++; }); check(late == 1, "Late subscription receives completion");
			var twice = false; try ticket.resolve(Applied) catch (_:Dynamic) twice = true;
			check(twice, "Completion is one-shot");
			var context = new BuildContext(new StateStore()); context.setCommandContext(commands);
			var editor = new PropertyEditor("editor", [descriptor]);
			ticket = new PropertyPendingEdit();
			check(!editor.applyValue(context, descriptor, PropertyValue.Int(3)), "Pending is not reported as applied");
			var count = submissions;
			editor.applyValue(context, descriptor, PropertyValue.Int(4));
			check(submissions == count, "Duplicate row submission is blocked until acknowledgment");
			var revision = editor.revision; ticket.resolve(Rejected("Rejected"));
			check(editor.revision > revision && value == 1, "Rejection invalidates row without changing model");
			ticket = new PropertyPendingEdit(); editor.applyValue(context, descriptor, PropertyValue.Int(4));
			value = 4; revision = editor.revision; ticket.resolve(Applied);
			check(editor.revision > revision && document.history.undoCount == 0, "Acceptance updates row without second undo stack");
			var sync = new PropertyDescriptor("sync", "Sync", PropertyType.Int, _ -> PropertyValue.Int(value), (_, next) -> {
				switch next { case Int(number): value = number; default: }
			});
			check(new PropertyBinding(sync, commands).apply(PropertyValue.Int(7)) == Applied, "Synchronous editing still applies");
			check(document.history.undoCount == 1 && document.undo() && value == 4 && document.redo() && value == 7, "Synchronous undo and redo remain intact");
			var vector = new NumericVectorPropertyEditor(); var list = new ListPropertyEditor();
			var registry = new PropertyEditorRegistry([vector, list]);
			var vectorDescriptor = new PropertyDescriptor("vector", "Vector", PropertyType.Custom(NumericVectorPropertyEditor.TYPE),
				_ -> Custom(NumericVectorPropertyEditor.TYPE, [1.0, 2.0]), (_, _) -> {}, options);
			var valid = registry.parse(vectorDescriptor.type, "[2,3]");
			check(valid != null && registry.validate(commands, vectorDescriptor, valid) == null, "Vector JSON import and validation");
			check(registry.validate(commands, vectorDescriptor, Custom(NumericVectorPropertyEditor.TYPE, [20.0, 2.0])) != null, "Component bounds validated");
			check(registry.parse(PropertyType.Custom(ListPropertyEditor.TYPE), "[[[0,0],[4,0],[4,3]]]") != null, "Nested lists import without domain dependencies");
			check(registry.parse(PropertyType.Custom(ListPropertyEditor.TYPE), "{}") == null, "List import rejects objects");
			structuredControls(); recordControls();
			Sys.println("Property asynchronous binding, synchronous history and structured value tests passed"); return 0;
		} catch (error:Dynamic) { Sys.println(Std.string(error)); return 1; }
	}
	static function recordControls():Void {
		var editor = new RecordPropertyEditor(), options = new PropertyDescriptorOptions();
		options.structure = Record([
			new PropertyRecordField("enabled", Value(Bool)),
			new PropertyRecordField("nested", Record([new PropertyRecordField("flag", Value(Bool))])),
			new PropertyRecordField("extra", Value(Bool), true, false)
		]);
		var original:Dynamic = {enabled:true, nested:{flag:true}};
		var current:Dynamic = original, submissions = 0, reject = true;
		var descriptor = new PropertyDescriptor("settings", "Settings", Custom(RecordPropertyEditor.TYPE),
			_ -> Custom(RecordPropertyEditor.TYPE, current), (_, _) -> {}, options);
		var context = new BuildContext(new StateStore());
		function action(label:String, enabled:Bool = true):Void {
			context.beginFrame();
			var root = editor.build("settings", descriptor, Custom(RecordPropertyEditor.TYPE, current), context, enabled, next -> {
				submissions++; if (!reject) switch next { case Custom(_, data): current = data; default: }
			}).build(context);
			var target:RenderNode = null;
			root.walk(node -> { if (node.semantics != null && node.semantics.label == label) target = node; });
			check(target != null, "Record action exists: " + label);
			var dispatcher = new EventDispatcher(new FocusManager()); dispatcher.setRoot(root);
			dispatcher.targetEvent(UiEventKind.Activate, target.id);
		}
		action("Settings item extra Add");
		action("Settings item enabled"); action("Settings item nested.flag");
		check(current == original && submissions == 0 && !Reflect.hasField(original, "extra"), "Record changes stage without mutating omitted fields");
		action("Apply Settings"); check(submissions == 1 && current == original, "Rejected record remains uncommitted");
		reject = false; action("Apply Settings");
		check(submissions == 2 && current.enabled == false && current.nested.flag == false && current.extra == false,
			"Rejected record draft retains related nested changes for one retry");
		check(original.enabled == true && original.nested.flag == true && !Reflect.hasField(original, "extra"), "Original nested record stays detached");
		action("Settings item extra Remove"); action("Apply Settings");
		check(!Reflect.hasField(current, "extra"), "Optional record presence can be removed");
		action("Settings item extra Add"); action("Revert record draft"); action("Apply Settings");
		check(!Reflect.hasField(current, "extra"), "Revert restores absent optional field");
		action("Settings item extra Add", false); action("Apply Settings");
		check(!Reflect.hasField(current, "extra"), "Disabled record controls cannot stage edits");
		check(editor.parse("[]") == null && editor.parse("{}") != null, "Record root type is enforced");
	}

	static function structuredControls():Void {
		var list = new ListPropertyEditor();
		list.retainDrafts = true;
		var original:Array<Dynamic> = [true, false, true];
		var current:Dynamic = original;
		var descriptor = new PropertyDescriptor("items", "Items", PropertyType.Custom(ListPropertyEditor.TYPE),
			_ -> Custom(ListPropertyEditor.TYPE, current), (_, _) -> {});
		var context = new BuildContext(new StateStore());
		function action(label:String, enabled:Bool = true):Void {
			context.beginFrame();
			var view = list.build("items", descriptor, Custom(ListPropertyEditor.TYPE, current), context, enabled, next -> {
				switch next { case Custom(_, value): current = value; default: throw "Wrong custom value"; }
			});
			var root = view.build(context);
			var target:Null<RenderNode> = null;
			root.walk(node -> { if (node.semantics != null && node.semantics.label == label) target = node; });
			check(target != null, "Structured action has an accessible label: " + label);
			var dispatcher = new EventDispatcher(new FocusManager()); dispatcher.setRoot(root);
			var control:RenderNode = target;
			dispatcher.targetEvent(UiEventKind.Activate, control.id);
		}
		action("Items Add item");
		check(current == original, "List changes are staged before application");
		check(list.hasDrafts(), "Staged edits report unsaved changes");
		context = new BuildContext(new StateStore());
		action("Apply Items");
		check(haxe.Json.stringify(current) == "[true,false,true,true]" && original.length == 3, "Add produces a detached candidate");
		check(!list.hasDrafts(), "Successful Apply clears unsaved changes after rebuilding the inspector");
		action("Items item 2 Remove");
		action("Apply Items");
		check(haxe.Json.stringify(current) == "[true,false,true]", "Remove addresses the selected item");
		action("Items item 1 Up");
		action("Apply Items");
		check(haxe.Json.stringify(current) == "[false,true,true]", "Reorder moves the selected item");
		action("Items Add item");
		check(list.hasDrafts(), "Adding another item is unsaved");
		list.discardDrafts();
		check(!list.hasDrafts(), "Discard clears pending list changes");
		action("Items Add item", false);
		check(haxe.Json.stringify(current) == "[false,true,true]", "Disabled controls cannot submit");
		var options = new PropertyDescriptorOptions();
		options.structure = PropertyStructure.List(PropertyStructure.Value(PropertyType.Bool), 3, 3, "toggle");
		descriptor = new PropertyDescriptor("items", "Items", PropertyType.Custom(ListPropertyEditor.TYPE),
			_ -> Custom(ListPropertyEditor.TYPE, current), (_, _) -> {}, options);
		action("Items Add item"); action("Items item 0 Remove"); action("Apply Items");
		check(haxe.Json.stringify(current) == "[false,true,true]", "Typed list cardinality disables invalid add/remove actions");

	}

}
