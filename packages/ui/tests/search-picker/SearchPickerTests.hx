import haxeon.platform.NativeKitRuntime;
import haxeon.ui.FontCollection;
import haxeon.ui.LayoutAxis;
import haxeon.ui.LayoutFrame;
import haxeon.ui.LayoutStyle;
import haxeon.ui.core.Command;
import haxeon.ui.core.CommandRegistry;
import haxeon.ui.core.RenderNode;
import haxeon.ui.core.UiContext;
import haxeon.ui.core.UiEventKind;
import haxeon.ui.core.UiKey;
import haxeon.ui.semantics.AccessibilityRole;
import haxeon.ui.semantics.AccessibilityState;
import haxeon.ui.widgets.commands.CommandPalette;
import haxeon.ui.widgets.commands.SearchPicker;
import haxeon.ui.widgets.commands.SearchPickerModel;
import haxeon.ui.widgets.text.Text;

private class Results implements SearchPickerModel {
	public var selected:Int = 0;
	public var value:String = "";
	public var accepted:Int = -1;
	public function new() {}
	public function query():String return value;
	public function selectedIndex():Int return selected;
	public function count():Int return value == "" ? 50000 : 2;
	public function labelAt(index:Int):String return "Result " + index;
	public function enabledAt(index:Int):Bool return index != 1;
	public function setQuery(value:String):Void { this.value = value; selected = 0; }
	public function activate(index:Int):Void accepted = index;
	public function navigate(key:Int, modifiers:Int, pageSize:Int):Void {
		if (key == UiKey.Enter) { activate(selected); return; }
		var delta = key == UiKey.Up || key == UiKey.PageUp ? -1 : 1;
		var steps = key == UiKey.PageUp || key == UiKey.PageDown ? pageSize : 1;
		selected = (selected + delta * steps + count()) % count();
	}
}

class SearchPickerTests {
	static function check(value:Bool, message:String):Void if (!value) throw message;
	static function row(root:RenderNode, label:String):RenderNode {
		var found:RenderNode = null;
		root.walk(function(node) {
			if (node.semantics != null && node.semantics.role == AccessibilityRole.CollectionItem && node.semantics.label == label) found = node;
		});
		if (found == null) throw "Missing result: " + label;
		return found;
	}
	static function click(ui:UiContext, node:RenderNode, button:Int):Void {
		var bounds = node.globalBounds();
		ui.pointerDown(bounds.x + 12, bounds.y + bounds.height / 2, button);
		ui.pointerUp(bounds.x + 12, bounds.y + bounds.height / 2, button);
	}
	static function main():Int {
		// These defaults must compile and run without an application's settings package.
		var scheduler = new haxeon.ui.animation.AnimationScheduler(), visible = false;
		var delay = new haxeon.ui.widgets.overlays.TooltipHoverDelay(scheduler, function(value) visible = value);
		delay.start(); scheduler.advance(0.4); check(!visible, "Shared tooltip ignored its initial delay");
		scheduler.advance(0.41); check(visible, "Shared tooltip delay never completed"); delay.dispose();
		var placement = haxeon.ui.widgets.overlays.Tooltip.place(390, 40, 0, 400);
		check(390 + placement.x + placement.width + 20 <= 394, "Shared tooltip escaped its bounds");
		var runtime = new NativeKitRuntime();
		var fonts = FontCollection.create(); fonts.addSystemFallbacks();
		var ui = new UiContext(null, fonts);
		var model = new Results(), built = 0;
		var picker = new SearchPicker("results", model, function(context, index, selected, hovered, revision) {
			built++;
			var style = new LayoutStyle(); style.width = LayoutAxis.grow(); style.height = LayoutAxis.fixed(32);
			return new Text(model.labelAt(index), style);
		}, function() {}, function() {});
		var frame = new LayoutFrame(720, 480);
		var root = ui.submit(picker, frame);
		check(built > 0 && built < 40, "Picker materialized all results");
		var focus = ui.focus.focusedNode();
		check(focus != null && focus.styleType == "text-field", "Picker did not focus its input");
		ui.key(UiEventKind.KeyDown, UiKey.Up);
		root = ui.submit(picker, frame);
		root = ui.submit(picker, frame);
		var last = row(root, "Result 49999").globalBounds();
		check(last.y >= 40 && last.y + last.height <= 430, "Keyboard selection was not revealed");
		ui.key(UiEventKind.KeyDown, UiKey.PageUp);
		check(model.selected < 49998, "Page navigation did not use viewport size");
		ui.text(UiEventKind.TextInput, "filter");
		root = ui.submit(picker, frame);
		root = ui.submit(picker, frame);
		check(model.query() == "filter" && model.selected == 0, "Typing escaped the search input");
		var first = row(root, "Result 0"), disabled = row(root, "Result 1");
		var disabledSemantics:haxeon.ui.semantics.Semantics = cast disabled.semantics;
		check((disabledSemantics.states & AccessibilityState.Disabled) != 0, "Disabled result lost its accessible state");
		click(ui, first, 1); check(model.accepted == -1, "Secondary click accepted a result");
		click(ui, disabled, 0); check(model.accepted == -1, "Disabled result was accepted");
		click(ui, first, 0); check(model.accepted == 0, "Primary click did not accept its result");
		ui.dispose();

		ui = new UiContext(null, fonts);
		var commands = new CommandRegistry(), calls = 0, dismissals = 0;
		commands.register(new Command("enabled", "Enabled command", function() calls++));
		commands.register(new Command("disabled", "Disabled command", function() calls++, null, function() return false));
		var palette = new CommandPalette("palette", commands, null, 0, 0, "", function() dismissals++);
		palette.centered = true;
		root = ui.submit(palette, new LayoutFrame(480, 360));
		var panel = root.children[1].globalBounds();
		check(panel.x >= 7 && panel.x + panel.width <= 473 && panel.y >= 7 && panel.y + panel.height <= 353,
			"Centered command palette escaped its viewport");
		click(ui, row(root, "Disabled command"), 0);
		check(calls == 0, "Palette invoked a disabled command");
		ui.key(UiEventKind.KeyDown, UiKey.Down);
		ui.key(UiEventKind.KeyDown, UiKey.Enter);
		check(calls == 1 && dismissals == 1, "Palette failed to skip disabled commands and invoke once");
		ui.dispose(); fonts.dispose(); runtime.dispose();
		Sys.println("PASS: picker virtualization, input focus, reveal, filtering, paging, disabled/primary activation and command palette integration");
		return 0;
	}
}
