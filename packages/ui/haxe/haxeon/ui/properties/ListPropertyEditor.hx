package haxeon.ui.properties;

import haxeon.ui.core.*;
import haxeon.ui.LayoutAxis;
import haxeon.ui.LayoutStyle;
import haxeon.ui.widgets.KeyedView;
import haxeon.ui.widgets.controls.Button;
import haxeon.ui.widgets.controls.Checkbox;
import haxeon.ui.widgets.layout.Column;
import haxeon.ui.widgets.layout.Row;
import haxeon.ui.widgets.text.Text;
import haxeon.ui.widgets.text.TextField;

/** JSON-compatible list editor. Nested lists expose individual items; each action
 * stages a detached value. Apply submits the entire list as one transaction.
 * No schema, model mutation or undo history lives in this control.
 */
class ListPropertyEditor implements PropertyEditorExtension {
	public static inline var TYPE = "ui.list";
	final id:String;
	final vector:Bool;
	public function new(id:String = TYPE, vector:Bool = false) { this.id = id; this.vector = vector; }
	public function typeId():String return id;
	public function same(a:Dynamic, b:Dynamic):Bool return haxe.Json.stringify(a) == haxe.Json.stringify(b);
	public function display(value:Dynamic):String return haxe.Json.stringify(value);
	public function editableText(value:Dynamic):String return display(value);
	public function parse(text:String):Null<Dynamic> {
		try { var value:Dynamic = haxe.Json.parse(text); return Std.isOfType(value, Array) ? value : null; }
		catch (_:Dynamic) { return null; }
	}
	public function validate(context:CommandContext, descriptor:PropertyDescriptor, value:Dynamic):Null<String> {
		if (!Std.isOfType(value, Array)) return "A list is required";
		var items:Array<Dynamic> = cast value;
		if (vector) for (item in items) {
			if (!Std.isOfType(item, Int) && !Std.isOfType(item, Float)) return "Vector components must be numbers";
			var number:Float = cast item;
			if (!Math.isFinite(number)) return "Vector components must be finite";
			if (descriptor.minimum != null && number < descriptor.minimum) return "Component is below the minimum";
			if (descriptor.maximum != null && number > descriptor.maximum) return "Component is above the maximum";
		}
		return null;
	}
	static function style():LayoutStyle {
		var result = new LayoutStyle(); result.width = LayoutAxis.grow(); result.height = LayoutAxis.fit(); result.childGap = 4;
		return result;
	}
	public function build(key:String, descriptor:PropertyDescriptor, value:PropertyValue,
		context:BuildContext, enabled:Bool, apply:PropertyValue->Void):View {
		var root:Dynamic = switch value { case Custom(_, data): data; default: new Array<Dynamic>(); };
		var base = display(root);
		var draftState:State<ListPropertyDrafts> = context.state(context.id(key + ":drafts"), new ListPropertyDrafts(base));
		var local = draftState.value;
		if (local.base != base) {
			local = new ListPropertyDrafts(base);
			draftState.update(local);
		}
		var drafts = local.drafts;
		if (!vector) root = local.current;
		function candidate():Dynamic {
			var copy:Dynamic = haxe.Json.parse(vector ? base : haxe.Json.stringify(local.current));
			for (address in drafts.keys()) {
				var path:Array<Int> = address.split(":").map(part -> Std.parseInt(part));
				var previous:Dynamic = at(copy, path);
				var text = drafts.get(address);
				put(copy, path, Std.isOfType(previous, String) ? text : haxe.Json.parse(text));
			}
			return copy;
		}
		function commit():Void {
			try { apply(Custom(id, candidate())); }
			catch (_:Dynamic) { apply(Custom(id, "Invalid list item")); }
		}
		function stage(copy:Dynamic):Void {
			if (vector) apply(Custom(id, copy));
			else {
				local.current = copy; drafts.clear(); draftState.update(local);
				context.commands.refresh();
			}
		}
		function send(path:Array<Int>, next:Dynamic):Void {
			try { var copy = candidate(); put(copy, path, next); stage(copy); }
			catch (_:Dynamic) { apply(Custom(id, "Invalid list item")); }
		}
		function editList(path:Array<Int>, edit:Array<Dynamic>->Void):Void {
			try { var copy = candidate(); var items:Array<Dynamic> = cast at(copy, path); edit(items); stage(copy); }
			catch (_:Dynamic) { apply(Custom(id, "Invalid list item")); }
		}
		function leaf(path:Array<Int>, item:Dynamic, compact:Bool = false, component:String = null):View {
			var address = path.join(":"), draftKey = address;
			var label = component == null ? descriptor.label + " " + (vector && path.length == 1 ?
				(path[0] < 4 ? ["X", "Y", "Z", "W"][path[0]] : Std.string(path[0])) : "item " + path.join(".")) :
				descriptor.label + (path.length == 1 ? "" : " item " + path.slice(0, path.length - 1).join(".")) + " " + component;
			if (Std.isOfType(item, Bool)) {
				var box = new Checkbox("item:" + address, label, cast item, next -> send(path, next)); box.enabled = enabled; return box;
			}
			var initial = Std.isOfType(item, String) ? (cast item:String) : haxe.Json.stringify(item);
			var field = new TextField("item:" + address, drafts.exists(draftKey) ? drafts.get(draftKey) : initial,
				text -> { drafts.set(draftKey, text); draftState.update(local); }, compact ? new LayoutStyle() : style(), label);
			field.enabled = enabled;
			field.onSubmit = text -> {
				drafts.set(draftKey, text); draftState.update(local); commit();
			};
			return new Column("leaf:" + address, [new KeyedView("label", new Text(compact ? component : label)), new KeyedView("input", field)], style());
		}
		function tree(path:Array<Int>, item:Dynamic, structure:Null<PropertyStructure>):View {
			if (!Std.isOfType(item, Array) || path.length >= 8) return leaf(path, item);
			var items:Array<Dynamic> = cast item;
			var itemStructure:Null<PropertyStructure> = null;
			var minimumLength:Null<Int> = null, maximumLength:Null<Int> = null;
			var itemLabel = "Item";
			if (structure != null) switch structure {
				case Vector(components):
					if (components <= 0 || items.length != components) return new Text("Invalid vector dimensions");
					var columns:Array<KeyedView> = [];
					for (index in 0...components) {
						var label = index < 4 ? ["X", "Y", "Z", "W"][index] : Std.string(index);
						columns.push(new KeyedView("component:" + index, leaf(path.concat([index]), items[index], true, label)));
					}
					return new Row("vector:" + path.join(":"), columns, style());
				case List(child, minimum, maximum, label):
					itemStructure = child; minimumLength = minimum; maximumLength = maximum;
					itemLabel = label == null || label.length == 0 ? "Item" : label;
				default:
			}
			var children:Array<KeyedView> = [];
			for (index in 0...items.length) {
				var childPath = path.concat([index]);
				if (structure != null && !vector) children.push(new KeyedView("heading:" + index,
					new Text(itemLabel.charAt(0).toUpperCase() + itemLabel.substr(1) + " " + (index + 1))));
				children.push(new KeyedView("item:" + index, tree(childPath, items[index], itemStructure)));
				if (!vector) {
					var actions:Array<KeyedView> = [];
					function action(label:String, suffix:String, edit:Array<Dynamic>->Void, available:Bool):Void {
						var button = new Button(label, null, () -> editList(path, edit),
							"item:" + childPath.join(":") + ":" + suffix);
						button.accessibilityLabel = descriptor.label + " item " + childPath.join(".") + " " + label;
						button.enabled = enabled && available; actions.push(new KeyedView(suffix, button));
					}
					action("Remove", "remove", copy -> { copy.splice(index, 1); }, minimumLength == null || items.length > minimumLength);
					action("Up", "up", copy -> { var previous = copy[index - 1]; copy[index - 1] = copy[index]; copy[index] = previous; }, index > 0);
					children.push(new KeyedView("actions:" + index, new Row("actions", actions, style())));
				}
			}
			if (!vector) {
				var add = new Button("Add " + itemLabel.toLowerCase(), null, () -> editList(path, copy -> {
					// Duplicate the last structure; an empty list starts with null.
					copy.push(copy.length == 0 ? null : haxe.Json.parse(haxe.Json.stringify(copy[copy.length - 1])));
				}), "add:" + path.join(":"));
				add.accessibilityLabel = descriptor.label + (path.length == 0 ? "" : " item " + path.join(".")) + " Add item";
				add.enabled = enabled && (maximumLength == null || items.length < maximumLength); children.push(new KeyedView("add", add));
			}
			return new Column("list:" + path.join(":"), children, style());
		}
		var children:Array<KeyedView> = [];
		if (!vector) {
			var applyButton = new Button("Apply " + descriptor.label, null, commit, "apply");
			applyButton.enabled = enabled;
			children.push(new KeyedView("apply", applyButton));
			var revert = new Button("Revert list draft", null, () -> {
				draftState.update(new ListPropertyDrafts(base)); context.commands.refresh();
			}, "revert");
			revert.enabled = enabled;
			children.push(new KeyedView("revert", revert));
		}
		children.push(new KeyedView("items", tree(new Array<Int>(), root, descriptor.structure)));
		return new Column(key, children, style());
	}
	static function at(value:Dynamic, path:Array<Int>):Dynamic {
		for (index in path) value = (cast value:Array<Dynamic>)[index];
		return value;
	}
	static function put(value:Dynamic, path:Array<Int>, next:Dynamic):Void {
		if (path.length == 0) throw "A list item path is required";
		var parent = at(value, path.slice(0, path.length - 1));
		(cast parent:Array<Dynamic>)[path[path.length - 1]] = next;
	}

}

private class ListPropertyDrafts {
	public final base:String;
	public var current:Dynamic;
	public final drafts:Map<String, String> = new Map();
	public function new(base:String) { this.base = base; current = haxe.Json.parse(base); }
}
