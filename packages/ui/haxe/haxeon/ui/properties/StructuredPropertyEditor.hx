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

/** JSON-compatible structured editor. Nested lists expose individual items; each action
 * stages a detached value. Apply submits the entire value as one transaction.
 * Domain validation, model mutation and undo history remain application-owned.
 */
class StructuredPropertyEditor implements PropertyEditorExtension {
	/** Optional host chooser; selected paths join the staged list until Apply. */
	public var chooseItems:Null<(Array<String>->Void)->Void>;
	/** Keep drafts when an inspector is rebuilt or changes category. */
	public var retainDrafts:Bool = false;
	public var onDraftChanged:Null<Void->Void>;
	final retainedDrafts:Map<String, StructuredPropertyDrafts> = new Map();
	public function hasDrafts():Bool {
		for (draft in retainedDrafts) if (draft.dirty) return true;
		return false;
	}
	public function discardDrafts():Void {
		retainedDrafts.clear();
		if (onDraftChanged != null) onDraftChanged();
	}
	final id:String;
	final vector:Bool;
	final record:Bool;
	public function new(id:String, vector:Bool = false, record:Bool = false) { this.id = id; this.vector = vector; this.record = record; }
	public function typeId():String return id;
	public function same(a:Dynamic, b:Dynamic):Bool return haxe.Json.stringify(a) == haxe.Json.stringify(b);
	public function display(value:Dynamic):String return haxe.Json.stringify(value);
	public function editableText(value:Dynamic):String return display(value);
	public function parse(text:String):Null<Dynamic> {
		try { var value:Dynamic = haxe.Json.parse(text); return validRoot(value) ? value : null; }
		catch (_:Dynamic) { return null; }
	}
	public function validate(context:CommandContext, descriptor:PropertyDescriptor, value:Dynamic):Null<String> {
		if (!validRoot(value)) return record ? "A record is required" : "A list is required";
		var items:Array<Dynamic> = vector ? cast value : [];
		if (vector) for (item in items) {
			if (!Std.isOfType(item, Int) && !Std.isOfType(item, Float)) return "Vector components must be numbers";
			var number:Float = cast item;
			if (!Math.isFinite(number)) return "Vector components must be finite";
			if (descriptor.minimum != null && number < descriptor.minimum) return "Component is below the minimum";
			if (descriptor.maximum != null && number > descriptor.maximum) return "Component is above the maximum";
		}
		return null;
	}
	function validRoot(value:Dynamic):Bool return record ? value != null && Reflect.isObject(value)
		&& !Std.isOfType(value, Array) && !Std.isOfType(value, String) : Std.isOfType(value, Array);
	static function style():LayoutStyle {
		var result = new LayoutStyle(); result.width = LayoutAxis.grow(); result.height = LayoutAxis.fit(); result.childGap = 4;
		return result;
	}
	public function build(key:String, descriptor:PropertyDescriptor, value:PropertyValue,
		context:BuildContext, enabled:Bool, apply:PropertyValue->Void):View {
		var root:Dynamic = switch value { case Custom(_, data): data; default: new Array<Dynamic>(); };
		var base = display(root);
		var draftState:State<StructuredPropertyDrafts> = context.state(context.id(key + ":drafts"), new StructuredPropertyDrafts(base));
		var local = retainDrafts ? retainedDrafts.get(descriptor.id) : draftState.value;
		if (local == null) local = new StructuredPropertyDrafts(base);
		if (local.base != base) {
			local = new StructuredPropertyDrafts(base);
			draftState.update(local);
		}
		if (retainDrafts) retainedDrafts.set(descriptor.id, local);
		var drafts = local.drafts;
		if (!vector) root = local.current;
		function candidate():Dynamic {
			var copy:Dynamic = haxe.Json.parse(vector ? base : haxe.Json.stringify(local.current));
			for (address in drafts.keys()) {
				var path:Array<String> = cast haxe.Json.parse(address);
				var previous:Dynamic = at(copy, path);
				var text = drafts.get(address);
				put(copy, path, Std.isOfType(previous, String) ? text : haxe.Json.parse(text));
			}
			return copy;
		}
		function changed():Void {
			try { local.dirty = display(candidate()) != base; } catch (_:Dynamic) { local.dirty = true; }
			draftState.update(local);
			if (onDraftChanged != null) onDraftChanged();
			context.commands.refresh();
		}
		function commit():Void {
			try {
				var next = candidate();
				apply(Custom(id, next));
				var saved = descriptor.readValue(context.commandContext);
				if (switch saved { case Custom(_, data): same(data, next); default: false; }) {
					local.dirty = false;
					if (retainDrafts) retainedDrafts.remove(descriptor.id);
				}
				if (onDraftChanged != null) onDraftChanged();
			}
			catch (_:Dynamic) { apply(Custom(id, "Invalid structured value")); }
		}
		function stage(copy:Dynamic):Void {
			if (vector) apply(Custom(id, copy));
			else {
				local.current = copy; drafts.clear(); changed();
				context.commands.refresh();
			}
		}
		function send(path:Array<String>, next:Dynamic):Void {
			try { var copy = candidate(); put(copy, path, next); stage(copy); }
			catch (_:Dynamic) { apply(Custom(id, "Invalid structured value")); }
		}
		function editList(path:Array<String>, edit:Array<Dynamic>->Void):Void {
			try { var copy = candidate(); var items:Array<Dynamic> = cast at(copy, path); edit(items); stage(copy); }
			catch (_:Dynamic) { apply(Custom(id, "Invalid structured value")); }
		}
		function leaf(path:Array<String>, item:Dynamic, compact:Bool = false, component:String = null, inlineField:Bool = false):View {
			var address = haxe.Json.stringify(path), draftKey = address;
			var label = component == null ? descriptor.label + " " + (vector && path.length == 1 ?
				(Std.parseInt(path[0]) < 4 ? ["X", "Y", "Z", "W"][Std.parseInt(path[0])] : Std.string(path[0])) : "item " + path.join(".")) :
				descriptor.label + (path.length == 1 ? "" : " item " + path.slice(0, path.length - 1).join(".")) + " " + component;
			if (Std.isOfType(item, Bool)) {
				var box = new Checkbox("item:" + address, label, cast item, next -> send(path, next)); box.enabled = enabled; return box;
			}
			var initial = Std.isOfType(item, String) ? (cast item:String) : haxe.Json.stringify(item);
			var field = new TextField("item:" + address, drafts.exists(draftKey) ? drafts.get(draftKey) : initial,
				text -> { drafts.set(draftKey, text); changed(); }, compact ? new LayoutStyle() : style(), label);
			field.enabled = enabled;
			field.onSubmit = text -> {
				drafts.set(draftKey, text); changed(); commit();
			};
			if (inlineField) return field;
			var displayLabel = compact ? component : label;
			if (!compact && path.length > 0 && !~/^[0-9]+$/.match(path[path.length - 1])) displayLabel = path[path.length - 1];
			return new Column("leaf:" + address, [new KeyedView("label", new Text(displayLabel)), new KeyedView("input", field)], style());
		}
		function tree(path:Array<String>, item:Dynamic, structure:Null<PropertyStructure>):View {
			if (path.length >= 8) return leaf(path, item);
			if (structure != null) switch structure {
				case Record(fields):
					if (item == null || !Reflect.isObject(item) || Std.isOfType(item, Array) || Std.isOfType(item, String))
						return leaf(path, item);
					var children:Array<KeyedView> = [];
					for (field in fields) {
						var fieldPath = path.concat([field.name]);
						var label = descriptor.label + " item " + fieldPath.join(".");
						switch field.structure {
							case Value(_):
							default: children.push(new KeyedView("label:" + field.name, new Text(field.name)));
						}
						if (Reflect.hasField(item, field.name)) {
							children.push(new KeyedView("field:" + field.name, tree(fieldPath, Reflect.field(item, field.name), field.structure)));
							if (field.optional) {
								var remove = new Button("Remove " + field.name, null, () -> {
									try { var copy = candidate(); Reflect.deleteField(at(copy, path), field.name); stage(copy); }
									catch (_:Dynamic) { apply(Custom(id, "Invalid structured value")); }
								}, "remove:" + field.name);
								remove.accessibilityLabel = label + " Remove"; remove.enabled = enabled;
								children.push(new KeyedView("remove:" + field.name, remove));
							}
						} else {
							var add = new Button("Add " + field.name, null, () -> send(fieldPath, field.initialValue()), "add:" + field.name);
							add.accessibilityLabel = label + " Add"; add.enabled = enabled;
							children.push(new KeyedView("add:" + field.name, add));
						}
					}
					return new Column("record:" + haxe.Json.stringify(path), children, style());
				default:
			}
			if (!Std.isOfType(item, Array)) return leaf(path, item);
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
						columns.push(new KeyedView("component:" + index, leaf(path.concat([Std.string(index)]), items[index], true, label)));
					}
					return new Row("vector:" + path.join(":"), columns, style());
				case List(child, minimum, maximum, label):
					itemStructure = child; minimumLength = minimum; maximumLength = maximum;
					itemLabel = label == null || label.length == 0 ? "Item" : label;
				default:
			}
			var children:Array<KeyedView> = [];
			for (index in 0...items.length) {
				var childPath = path.concat([Std.string(index)]);
				var simple = !vector && (Std.isOfType(items[index], String) || Std.isOfType(items[index], Int) || Std.isOfType(items[index], Float));
				var row:Array<KeyedView> = [];
				if (simple) {
					var numberStyle = new LayoutStyle(); numberStyle.width = LayoutAxis.fixed(24);
					row.push(new KeyedView("number", new Text(Std.string(index + 1) + ".", numberStyle)));
					row.push(new KeyedView("value", leaf(childPath, items[index], false, itemLabel + " " + (index + 1), true)));
				} else {
					if (structure != null && !vector) children.push(new KeyedView("heading:" + index,
						new Text(itemLabel.charAt(0).toUpperCase() + itemLabel.substr(1) + " " + (index + 1))));
					children.push(new KeyedView("item:" + index, tree(childPath, items[index], itemStructure)));
				}
				if (!vector) {
					var actions:Array<KeyedView> = [];
					function action(label:String, suffix:String, icon:haxeon.ui.icons.IconName, edit:Array<Dynamic>->Void, available:Bool):Void {
						var buttonStyle = new LayoutStyle();
						buttonStyle.width = LayoutAxis.fixed(28); buttonStyle.height = LayoutAxis.fixed(28);
						buttonStyle.padding = new haxeon.ui.Insets(4, 4, 4, 4);
						var button = new Button("", buttonStyle, () -> editList(path, edit),
							"item:" + childPath.join(":") + ":" + suffix);
						button.leadingIcon = icon; button.iconSize = 14;
						button.accessibilityLabel = descriptor.label + " item " + childPath.join(".") + " " + label;
						button.enabled = enabled && available;
						(simple ? row : actions).push(new KeyedView(suffix, button));
					}
					action("Up", "up", haxeon.ui.icons.IconName.ArrowUp,
						copy -> { var previous = copy[index - 1]; copy[index - 1] = copy[index]; copy[index] = previous; }, index > 0);
					action("Remove", "remove", haxeon.ui.icons.IconName.Trash,
						copy -> { copy.splice(index, 1); }, minimumLength == null || items.length > minimumLength);
					if (!simple) children.push(new KeyedView("actions:" + index, new Row("actions", actions, style())));
				}
				if (simple) {
					var rowStyle = style(); rowStyle.childAlignY = haxeon.ui.LayoutAlignmentY.Center;
					children.push(new KeyedView("item:" + index, new Row("item-row:" + index, row, rowStyle)));
				}
			}
			if (!vector) {
				var add = new Button("Add " + itemLabel.toLowerCase(), null, () -> editList(path, copy -> {
					// Duplicate the last item; typed empty lists start from presentation metadata.
					copy.push(copy.length == 0 ? initial(itemStructure) : haxe.Json.parse(haxe.Json.stringify(copy[copy.length - 1])));
				}), "add:" + path.join(":"));
				add.accessibilityLabel = descriptor.label + (path.length == 0 ? "" : " item " + path.join(".")) + " Add item";
				add.enabled = enabled && (maximumLength == null || items.length < maximumLength); children.push(new KeyedView("add", add));
			}
			return new Column("list:" + path.join(":"), children, style());
		}
		var children:Array<KeyedView> = [];
		if (!vector) {
			if (local.dirty) children.push(new KeyedView("unsaved", new Text("Unsaved changes")));
			var applyButton = new Button("Apply", null, commit, "apply");
			applyButton.accessibilityLabel = "Apply " + descriptor.label;
			applyButton.enabled = enabled && local.dirty;
			var revert = new Button("Revert", null, () -> {
				local = new StructuredPropertyDrafts(base);
				if (retainDrafts) retainedDrafts.set(descriptor.id, local);
				draftState.update(local);
				if (onDraftChanged != null) onDraftChanged();
				context.commands.refresh();
			}, "revert");
			revert.accessibilityLabel = record ? "Revert record draft" : "Revert list draft";
			revert.enabled = enabled && local.dirty;
			children.push(new KeyedView("draft-actions", new Row("draft-actions", [
				new KeyedView("apply", applyButton), new KeyedView("revert", revert)
			], style())));
		}
		children.push(new KeyedView("items", tree(new Array<String>(), root, descriptor.structure)));
		var choose = chooseItems;
		if (!vector && choose != null) {
			var browse = new Button("Choose files…", null, function() choose(function(paths) {
				if (paths.length == 0) return;
				try {
					var copy:Array<Dynamic> = cast candidate();
					for (path in paths) copy.push(path);
					stage(copy);
				} catch (_:Dynamic) { apply(Custom(id, "Invalid structured value")); }
			}), "choose-files");
			browse.enabled = enabled;
			children.push(new KeyedView("choose-files", browse));
		}
		return new Column(key, children, style());
	}
	static function initial(structure:Null<PropertyStructure>):Dynamic {
		if (structure == null) return null;
		return switch structure {
			case Value(type): switch type { case Bool: false; case Int, Float: 0; case Text: ""; default: null; };
			case Vector(components): [for (_ in 0...components) 0];
			case List(items, minimum, _, _): [for (_ in 0...(minimum == null ? 0 : minimum)) initial(items)];
			case Record(fields):
				var result:Dynamic = {};
				for (field in fields) if (!field.optional) Reflect.setField(result, field.name, field.initialValue());
				result;
		};
	}

	static function at(value:Dynamic, path:Array<String>):Dynamic {
		for (part in path) value = Std.isOfType(value, Array) ? (cast value:Array<Dynamic>)[Std.parseInt(part)] : Reflect.field(value, part);
		return value;
	}
	static function put(value:Dynamic, path:Array<String>, next:Dynamic):Void {
		if (path.length == 0) throw "A list item path is required";
		var parent = at(value, path.slice(0, path.length - 1));
		var part = path[path.length - 1];
		if (Std.isOfType(parent, Array)) (cast parent:Array<Dynamic>)[Std.parseInt(part)] = next;
		else Reflect.setField(parent, part, next);
	}

}

private class StructuredPropertyDrafts {
	public final base:String;
	public var current:Dynamic;
	public var dirty:Bool = false;
	public final drafts:Map<String, String> = new Map();
	public function new(base:String) { this.base = base; current = haxe.Json.parse(base); }
}
