package haxeon.ui.widgets.controls;
import haxeon.ui.core.ViewRoot;
import haxeon.ui.widgets.KeyedView;
import haxeon.ui.widgets.layout.Align;
import haxeon.ui.widgets.layout.Row;
import haxeon.ui.widgets.text.TextField;

import haxeon.ui.Color;
import haxeon.ui.Insets;
import haxeon.ui.LayoutAxis;
import haxeon.ui.LayoutStyle;
import haxeon.ui.core.BuildContext;
import haxeon.ui.core.Key;
import haxeon.ui.core.RenderNode;
import haxeon.ui.core.View;
import haxeon.ui.icons.IconName;
import haxeon.ui.widgets.Icon;

import haxeon.ui.widgets.controls.Button;
/** Reusable single-line search input with leading affordance and clear action. */
class SearchField implements View {
	/** Identifies the field among its siblings, so its text and focus survive rebuilds: required, and never empty. */
	public final key:String;

	/** The query. */
	public final value:String;

	/** The hint shown while the query is empty; "Search" by default. */
	public final placeholder:String;

	/** The field's accessible name; the placeholder unless set. */
	public final label:String;

	/** Whether the field accepts input. */
	public final enabled:Bool;

	/** The field's box, with the search icon before the text. */
	public final style:LayoutStyle;

	/** Called with the query after each edit. */
	public final onChange:Null<String->Void>;

	/** Called with the query when the user presses Enter. */
	public final onSubmit:Null<String->Void>;

	/** A search field showing `value`. Throws when `key` is empty. */
	public function new(key:String,
			value:String = "",
			?onChange:String->Void,
			?style:LayoutStyle,
			placeholder:String = "Search",
			?label:String,
			enabled:Bool = true,
			?onSubmit:String->Void) {
		if (key == null || key.length == 0) throw "Search fields require a stable key";
		this.key = key;
		this.value = value == null ? "" : value;
		this.onChange = onChange;
		this.placeholder = placeholder == null || placeholder.length == 0 ? "Search" : placeholder;
		this.style = style == null ? defaultStyle() : style.copy();
		this.style.childAlignY = LayoutAlignmentY.Center;
		this.label = label == null ? this.placeholder : label;
		this.enabled = enabled;
		this.onSubmit = onSubmit;
	}

	public function build(context:BuildContext):ViewRoot {
		var value = this.value;
		return context.withScope(new Key(key), function() {
			// What the user typed last, until the caller gives a different query.
			var chosen = context.adopted("query", value);
			value = chosen.value;
			var icon = new Icon("search-icon", IconName.Search, 15.0, context.theme.tokens.textSecondary);
			var leadingStyle = new LayoutStyle();
			leadingStyle.width = LayoutAxis.fixed(18.0);
			leadingStyle.height = LayoutAxis.fixed(18.0);
			var leading = new Align("leading", icon, LayoutAlignmentX.Center, LayoutAlignmentY.Center, leadingStyle);

			var inputStyle = new LayoutStyle();
			inputStyle.width = LayoutAxis.grow();
			inputStyle.height = LayoutAxis.fixed(24.0);
			// The field's box is the row around it; the theme's search-input rule makes the input's own box invisible.
			var input = new TextField("input", value, function(next) {
				value = next;
				chosen.set(next);
				if (onChange != null) onChange(next);
			}, inputStyle, label, placeholder:, enabled:, classes: ["search-input"],
				onSubmit:);

			var children:Array<KeyedView> = [new KeyedView("icon", leading), new KeyedView("input", input)];
			if (value.length > 0) {
				var clearStyle = new LayoutStyle();
				clearStyle.width = LayoutAxis.fixed(24.0);
				clearStyle.height = LayoutAxis.fixed(24.0);
				clearStyle.padding = new Insets(2.0, 2.0, 2.0, 2.0);
				clearStyle.childDistribution = LayoutDistribution.Center;
				clearStyle.background = Color.rgba(0.0, 0.0, 0.0, 0.0);
				var clear = new Button("", clearStyle, function() {
					value = "";
					chosen.set("");
					if (onChange != null) onChange("");
				}, "clear", enabled,
					ButtonVariant.Navigation, null, null, IconName.Close, null, null, null, null, null, null,
					"Clear search");
				children.push(new KeyedView("clear", clear));
			}
			return new Row("search-field", children, style).build(context);
		});
	}

	static function defaultStyle():LayoutStyle {
		var result = new LayoutStyle();
		result.width = LayoutAxis.grow();
		result.height = LayoutAxis.fixed(38.0);
		result.padding = new Insets(10.0, 7.0, 10.0, 7.0);
		result.childGap = 8.0;
		result.childAlignY = LayoutAlignmentY.Center;
		return result;
	}
}
