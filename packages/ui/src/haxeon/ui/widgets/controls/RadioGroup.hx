package haxeon.ui.widgets.controls;
import haxeon.ui.core.ViewRoot;

import haxeon.ui.LayoutAxis;
import haxeon.ui.LayoutNode;
import haxeon.ui.LayoutStyle;
import haxeon.ui.core.BuildContext;
import haxeon.ui.core.Key;
import haxeon.ui.core.RenderNode;
import haxeon.ui.core.RootModifier;
import haxeon.ui.core.UiEvent;
import haxeon.ui.core.UiKey;
import haxeon.ui.core.View;
import haxeon.ui.semantics.Semantics;
import haxeon.ui.widgets.controls.Radio;

/** Exclusive radio options with stable selected state and arrow-key traversal. */
class RadioGroup implements View {
	final key:Key;
	/** The choices, in the order shown; keys and values are unique. */
	public final options:Array<RadioOption>;

	/** The chosen option's value. A disabled or unknown value gives way to the first enabled option. */
	public final value:String;

	/** The group's box, which stacks its buttons. */
	public final style:LayoutStyle;

	/** Called with the newly chosen value when the user picks another option. */
	public final onChange:String->Void;
	var hasChangeHandler:Bool;

	/** A group of radio buttons for `options`, with `value` chosen. Throws when two options share a key or a value. */
	public function new(key:String,
			options:Array<RadioOption>,
			value:String,
			?onChange:String->Void,
			?style:LayoutStyle) {
		this.key = new Key(key);
		this.options = options == null ? [] : options.copy();
		this.value = value == null ? "" : value;
		this.style = style == null ? defaultStyle() : style.copy();
		hasChangeHandler = onChange != null;
		this.onChange = onChange == null ? function(_) {}
			: onChange;
		var keys:Map<String, Bool> = new Map();
		var values:Map<String, Bool> = new Map();
		for (option in this.options) {
			if (option == null
				|| keys.exists(option.key)
				|| values.exists(option.value)) throw "Radio option keys and values must be unique";
			keys.set(option.key, true);
			values.set(option.value, true);
		}
	}

	public function build(context:BuildContext):ViewRoot {
		// What the user picks while this build is shown; the field stays the caller's input.
		var value = this.value;
		return context.withScope(key, function() {
			var root = context.createNode(context.rootId("radio-group"), LayoutVisualKind.Box, style.copy());
			root.semantics = new Semantics(AccessibilityRole.Group, "Radio group");
			// The user's last choice, until the caller gives a different value; a disabled one shows the first enabled.
			var chosen = context.adopted("value", value);
			var active:String = chosen.value;
			if (!hasEnabledValue(active)) active = firstEnabledValue();
			value = active;

			var nodes:Array<ViewRoot> = [];
			var select = function(next:String) {
				if (next == value) return;
				value = next;
				chosen.set(next);
				if (hasChangeHandler) onChange(next);
			};
			for (option in options) {
				var radio = new Radio(option.key, option.label, option.value, option.value == active, function(next) {
					select(next);
				}, null, option.enabled);
				var radioIndex = nodes.length;
				var modifier = new RootModifier();
				modifier.on(UiEventKind.KeyDown, function(event) {
					var direction = event.key == UiKey.Right
						|| event.key == UiKey.Down ? 1 : event.key == UiKey.Left || event.key == UiKey.Up ? -1 : 0;
					if (direction == 0 || nodes.length == 0) return;
					var nextIndex = radioIndex;
					for (_ in 0...nodes.length) {
						nextIndex = (nextIndex + direction + nodes.length) % nodes.length;
						if (options[nextIndex].enabled) break;
					}
					if (options[nextIndex].enabled) {
						select(options[nextIndex].value);
						context.requestFocus(nodes[nextIndex].id);
						event.preventDefault();
					}
				});
				var node = context.build(radio, modifier);
				root.add(node);
				nodes.push(node);
			}
			return root;
		});
	}

	function hasEnabledValue(value:String):Bool {
		for (option in options) if (option.enabled && option.value == value) return true;
		return false;
	}

	function firstEnabledValue():String {
		for (option in options) if (option.enabled) return option.value;
		return "";
	}

	static function defaultStyle():LayoutStyle {
		var result = new LayoutStyle();
		result.width = LayoutAxis.grow();
		result.childGap = 2.0;
		return result;
	}
}

/** One keyed option in a RadioGroup. */
class RadioOption {
	/** Identifies the option within its group, so its button keeps its state across rebuilds. */
	public final key:String;

	/** The text shown beside the button. */
	public final label:String;

	/** The value the group takes when this option is chosen. */
	public final value:String;

	/** Whether the option can be chosen. */
	public final enabled:Bool;

	/** An option for a `RadioGroup`. Throws when `key` or `value` is empty. */
	public function new(key:String, label:String, value:String, enabled:Bool = true) {
		if (key == null || key.length == 0 || value == null || value.length == 0)
			throw "Radio options require stable keys and non-empty values";
		this.key = key;
		this.label = label == null ? "" : label;
		this.value = value;
		this.enabled = enabled;
	}
}
