package nativekit.ui.widgets.settings;

import LayoutAlignmentY;
import LayoutAxis;
import LayoutDirection;
import LayoutStyle;
import Insets;
import nativekit.ui.core.BuildContext;
import nativekit.ui.core.RenderNode;
import nativekit.ui.core.Shortcut;
import nativekit.ui.core.UiEvent;
import nativekit.ui.core.UiEventKind;
import nativekit.ui.core.UiKey;
import nativekit.ui.core.View;
import nativekit.ui.icons.IconName;
import nativekit.ui.settings.SettingDefinition;
import nativekit.ui.settings.ShortcutBindings;
import nativekit.ui.widgets.KeyedView;
import nativekit.ui.widgets.controls.Button;
import nativekit.ui.widgets.controls.IconButton;
import nativekit.ui.widgets.controls.SearchField;
import nativekit.ui.widgets.layout.Column;
import nativekit.ui.widgets.layout.Row;
import nativekit.ui.widgets.scroll.ScrollView;
import nativekit.ui.widgets.text.Text;

/**
 * Lists every command with its shortcuts and lets the user rebind them.
 *
 * Commands are grouped by the first part of their ID ("editor.save" under
 * Editor). Clicking a shortcut records the next key chord: Escape cancels,
 * and modifier keys alone keep waiting. A chord another command in the same
 * scope used is moved to this one, and the panel says so.
 */
class ShortcutsPanel implements View {
	public final key:String;
	public final bindings:ShortcutBindings;
	public var filter(default, null):String;
	/** The command waiting for a key chord, or null. */
	public var recordingId(default, null):Null<String>;
	/** What the last change did besides the obvious, such as taking a chord from another command. */
	public var notice(default, null):Null<String>;
	public var onChanged:Null<Void->Void>;
	/** Width of each row's shortcut button. */
	public var shortcutWidth:Float;

	public function new(key:String, bindings:ShortcutBindings, ?onChanged:Void->Void) {
		if (key == null || key.length == 0)
			throw "Shortcut panels require a stable key";
		this.key = key;
		this.bindings = bindings;
		filter = "";
		recordingId = null;
		notice = null;
		this.onChanged = onChanged;
		shortcutWidth = 240.0;
	}

	public function setFilter(value:String):Void {
		var next = value == null ? "" : value;
		if (next == filter)
			return;
		filter = next;
		changed();
	}

	/** Starts recording a chord for the command; recording it again stops. */
	public function record(id:String):Void {
		recordingId = recordingId == id ? null : id;
		notice = null;
		changed();
	}

	/**
	 * Handles a key press while recording. Returns true when the press was
	 * used: assigned, cancelled with Escape, or a modifier held for a chord.
	 */
	public function press(key:Int, modifiers:Int):Bool {
		var id = recordingId;
		if (id == null)
			return false;
		if (Shortcut.isModifierKey(key))
			return true;
		recordingId = null;
		var normalized = Shortcut.normalizeModifiers(modifiers);
		if (key == UiKey.Escape && normalized == 0) {
			changed();
			return true;
		}
		var shortcut = new Shortcut(key, normalized);
		var taken = bindings.assign(id, shortcut);
		notice = taken.length == 0 ? null : shortcut.label() + " was moved from "
			+ [for (other in taken) labelOf(other)].join(", ") + ".";
		changed();
		return true;
	}

	public function clear(id:String):Void {
		bindings.clear(id);
		recordingId = null;
		notice = null;
		changed();
	}

	public function reset(id:String):Void {
		bindings.reset(id);
		recordingId = null;
		notice = null;
		// Resetting can bring back a chord another command has taken since.
		var scope = bindings.commands.scopeOf(id);
		if (scope != null)
			for (shortcut in bindings.commands.shortcutsFor(id)) {
				var others = [for (other in bindings.commands.commandsBoundTo(shortcut, scope)) if (other != id) labelOf(other)];
				if (others.length > 0)
					notice = shortcut.label() + " is also used by " + others.join(", ") + ".";
			}
		changed();
	}

	/** "Ctrl+S, Ctrl+Shift+S", or "None". */
	public function shortcutText(id:String):String {
		var shortcuts = bindings.commands.shortcutsFor(id);
		return shortcuts.length == 0 ? "None" : [for (shortcut in shortcuts) shortcut.label()].join(", ");
	}

	/** Visible command IDs by group, groups in order of their first command. */
	public function groups():Array<ShortcutGroup> {
		var result:Array<ShortcutGroup> = [];
		var text = StringTools.trim(filter).toLowerCase();
		for (id in bindings.commands.ids()) {
			if (text.length > 0 && labelOf(id).toLowerCase().indexOf(text) < 0 && id.indexOf(text) < 0
				&& shortcutText(id).toLowerCase().indexOf(text) < 0)
				continue;
			var name = groupOf(id);
			var group:Null<ShortcutGroup> = null;
			for (existing in result)
				if (existing.name == name)
					group = existing;
			if (group == null) {
				group = new ShortcutGroup(name);
				result.push(group);
			}
			group.ids.push(id);
		}
		return result;
	}

	public function build(context:BuildContext):RenderNode {
		var searchStyle = new LayoutStyle();
		searchStyle.width = LayoutAxis.grow();
		var rows:Array<KeyedView> = [];
		for (group in groups()) {
			var headingStyle = new LayoutStyle();
			headingStyle.padding = new Insets(0.0, 10.0, 0.0, 2.0);
			rows.push(new KeyedView("group:" + group.name, new Text(SettingDefinition.labelFor(group.name), headingStyle)));
			for (id in group.ids)
				rows.push(new KeyedView("command:" + id, row(id)));
		}
		if (rows.length == 0)
			rows.push(new KeyedView("empty", new Text("No commands match \"" + filter + "\".")));
		var listStyle = new LayoutStyle();
		listStyle.width = LayoutAxis.grow();
		listStyle.height = LayoutAxis.fit();
		listStyle.direction = LayoutDirection.TopToBottom;
		listStyle.childGap = 2.0;
		listStyle.padding = new Insets(4.0, 0.0, 12.0, 8.0);
		var scrollStyle = fill();
		var children:Array<KeyedView> = [
			new KeyedView("filter", new SearchField(key + ":filter", filter, setFilter, searchStyle, "Filter by name or shortcut")),
			new KeyedView("list", new ScrollView(key + ":list", new Column(key + ":rows", rows, listStyle), scrollStyle))
		];
		if (notice != null)
			children.push(new KeyedView("notice", new Text(notice)));
		var columnStyle = fill();
		columnStyle.childGap = 8.0;
		columnStyle.padding = new Insets(0.0, 8.0, 0.0, 0.0);
		return new Column(key, children, columnStyle).build(context);
	}

	function row(id:String):View {
		var labelStyle = new LayoutStyle();
		labelStyle.width = LayoutAxis.grow();
		var children:Array<KeyedView> = [new KeyedView("label", new Text(labelOf(id), labelStyle))];
		var recording = recordingId == id;
		var captureStyle = new LayoutStyle();
		captureStyle.width = LayoutAxis.fixed(shortcutWidth);
		var capture = new Button(recording ? "Press a shortcut... (Esc cancels)" : shortcutText(id), captureStyle,
			function() record(id), "shortcut:" + id);
		children.push(new KeyedView("capture", new ShortcutCapture(capture, recording, this)));
		if (bindings.commands.hasCustomShortcuts(id))
			children.push(new KeyedView("reset", new IconButton("shortcut-reset:" + id, IconName.Reset,
				"Reset " + labelOf(id) + " to its default shortcut", function() reset(id))));
		if (bindings.commands.shortcutsFor(id).length > 0)
			children.push(new KeyedView("clear", new IconButton("shortcut-clear:" + id, IconName.Close,
				"Remove the shortcuts of " + labelOf(id), function() clear(id))));
		var rowStyle = new LayoutStyle();
		rowStyle.width = LayoutAxis.grow();
		rowStyle.height = LayoutAxis.fit();
		rowStyle.direction = LayoutDirection.LeftToRight;
		rowStyle.childAlignY = LayoutAlignmentY.Center;
		rowStyle.childGap = 8.0;
		rowStyle.padding = new Insets(12.0, 0.0, 0.0, 0.0);
		return new Row(key + ":row:" + id, children, rowStyle);
	}

	function labelOf(id:String):String {
		var command = bindings.commands.get(id);
		return command == null ? id : command.label;
	}

	static function groupOf(id:String):String {
		var dot = id.indexOf(".");
		return dot <= 0 ? id : id.substr(0, dot);
	}

	function changed():Void
		if (onChanged != null)
			onChanged();

	static function fill():LayoutStyle {
		var style = new LayoutStyle();
		style.width = LayoutAxis.grow();
		style.height = LayoutAxis.grow();
		style.direction = LayoutDirection.TopToBottom;
		return style;
	}
}

/** Command IDs listed under one heading. */
class ShortcutGroup {
	public final name:String;
	public final ids:Array<String>;

	public function new(name:String) {
		this.name = name;
		ids = [];
	}
}

/** The shortcut button, which also takes the next key press while its row is recording. */
private class ShortcutCapture implements View {
	final button:Button;
	final recording:Bool;
	final panel:ShortcutsPanel;

	public function new(button:Button, recording:Bool, panel:ShortcutsPanel) {
		this.button = button;
		this.recording = recording;
		this.panel = panel;
	}

	public function build(context:BuildContext):RenderNode {
		var node = button.build(context);
		if (recording)
			node.on(UiEventKind.KeyDown, function(event:UiEvent) {
				if (panel.press(event.key, event.modifiers)) {
					// Keep the chord from running a command or closing the dialog.
					event.preventDefault();
					event.stopPropagation();
				}
			});
		return node;
	}
}
