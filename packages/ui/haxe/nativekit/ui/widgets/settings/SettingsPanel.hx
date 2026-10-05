package nativekit.ui.widgets.settings;

import LayoutAlignmentY;
import LayoutAxis;
import LayoutDirection;
import LayoutStyle;
import Insets;
import nativekit.ui.core.BuildContext;
import nativekit.ui.core.RenderNode;
import nativekit.ui.core.View;
import nativekit.ui.settings.SettingsCatalog;
import nativekit.ui.settings.SettingsStore;
import nativekit.ui.widgets.KeyedView;
import nativekit.ui.widgets.collections.TreeRootMetadata;
import nativekit.ui.widgets.collections.TreeView;
import nativekit.ui.widgets.collections.TreeViewModel;
import nativekit.ui.widgets.controls.SearchField;
import nativekit.ui.widgets.controls.Toggle;
import nativekit.ui.widgets.layout.Column;
import nativekit.ui.widgets.layout.Row;
import nativekit.ui.widgets.layout.SplitSide;
import nativekit.ui.widgets.layout.SplitView;
import nativekit.ui.widgets.layout.SplitViewOptions;
import nativekit.ui.widgets.properties.PropertyInspector;
import nativekit.ui.widgets.text.Text;

/**
 * Editor-settings browser: a filter and Advanced switch over a category tree,
 * with the selected category's settings in a sectioned inspector.
 *
 * Keep one panel for as long as the dialog is open; it holds the filter,
 * selection and inspector state between frames. Every state change calls
 * onChanged so the host can rebuild.
 */
class SettingsPanel implements View {
	public final key:String;
	public final catalog:SettingsCatalog;
	public var filter(default, null):String;
	public var showAdvanced(default, null):Bool;
	/** The category shown on the right, or null when nothing matches. */
	public var selectedCategory(default, null):Null<String>;
	public var onChanged:Null<Void->Void>;
	public var treeWidth:Float;
	public var labelWidth:Float;

	final treeModel:SettingsTreeModel;
	var inspector:Null<PropertyInspector>;
	var inspectorKey:String;

	public function new(key:String, store:SettingsStore, ?onChanged:Void->Void) {
		if (key == null || key.length == 0)
			throw "Settings panels require a stable key";
		this.key = key;
		catalog = new SettingsCatalog(store);
		filter = "";
		showAdvanced = false;
		selectedCategory = null;
		this.onChanged = onChanged;
		treeWidth = 220.0;
		labelWidth = 260.0;
		treeModel = new SettingsTreeModel();
		inspector = null;
		inspectorKey = "";
		refresh();
	}

	public function setFilter(value:String):Void {
		var next = value == null ? "" : value;
		if (next == filter)
			return;
		filter = next;
		refresh();
	}

	public function setShowAdvanced(value:Bool):Void {
		if (value == showAdvanced)
			return;
		showAdvanced = value;
		refresh();
	}

	/** Selects a category, or the first category under a tree group such as "interface". */
	public function select(key:String):Void {
		var target = treeModel.categoryFor(key);
		if (target == null || target == selectedCategory)
			return;
		selectedCategory = target;
		changed();
	}

	/** Categories the tree lists for the current filter, in order. */
	public function categories():Array<String>
		return treeModel.categories.copy();

	/** The inspector for the selected category; rebuilt only when the category, filter or Advanced switch changes. */
	public function currentInspector():Null<PropertyInspector> {
		if (selectedCategory == null)
			return null;
		var nextKey = selectedCategory + "|" + filter + "|" + showAdvanced;
		if (inspector == null || inspectorKey != nextKey) {
			inspector = new PropertyInspector(key + ":inspector:" + selectedCategory, null, null, null,
				catalog.sections(selectedCategory, filter, showAdvanced), null,
				SettingsCatalog.labelOf(selectedCategory) + " settings");
			inspectorKey = nextKey;
		}
		return inspector;
	}

	public function build(context:BuildContext):RenderNode {
		var headerStyle = new LayoutStyle();
		headerStyle.width = LayoutAxis.grow();
		headerStyle.height = LayoutAxis.fit();
		headerStyle.direction = LayoutDirection.LeftToRight;
		headerStyle.childAlignY = LayoutAlignmentY.Center;
		headerStyle.childGap = 12.0;
		var searchStyle = new LayoutStyle();
		searchStyle.width = LayoutAxis.grow();
		var header = new Row(key + ":header", [
			new KeyedView("filter", new SearchField(key + ":filter", filter, setFilter, searchStyle, "Filter Settings")),
			new KeyedView("advanced", new Toggle(key + ":advanced", "Advanced Settings", showAdvanced, setShowAdvanced))
		], headerStyle);

		var treeStyle = fill();
		var tree = new TreeView(key + ":tree:" + treeModel.revision(), treeModel, treeStyle, null, 400.0,
			selectedCategory, treeModel.groups(), select);

		var inspectorView:View = null;
		var current = currentInspector();
		if (current == null) {
			inspectorView = new Text(filter.length == 0 ? "No settings." : "No settings match \"" + filter + "\".");
		} else {
			current.labelWidth = labelWidth;
			var inspectorStyle = fill();
			inspectorStyle.padding = new Insets(12.0, 0.0, 4.0, 0.0);
			current.setStyle(inspectorStyle);
			inspectorView = current;
		}
		var options = new SplitViewOptions();
		options.resizableSide = SplitSide.Leading;
		options.extent = treeWidth;
		options.minimumExtent = 140.0;
		options.maximumExtent = 420.0;
		options.style = fill();
		options.dividerVisualExtent = 1.0;
		options.onResize = function(width) {
			treeWidth = width;
			changed();
		};
		var split = new SplitView(key + ":split", tree, inspectorView, options);

		var columnStyle = fill();
		columnStyle.childGap = 8.0;
		return new Column(key, [
			new KeyedView("header", header),
			new KeyedView("body", split)
		], columnStyle).build(context);
	}

	/** Recomputes the tree after the filter or Advanced switch changed, keeping the selection when it still matches. */
	function refresh():Void {
		treeModel.update(catalog.categories(filter, showAdvanced));
		if (selectedCategory == null || treeModel.categories.indexOf(selectedCategory) < 0)
			selectedCategory = treeModel.categories.length == 0 ? null : treeModel.categories[0];
		changed();
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

/**
 * Two-level tree over category paths: groups are first path segments
 * ("interface"), leaves are categories ("interface/editor"). A one-segment
 * category such as "network" is a group and a category at once.
 */
private class SettingsTreeModel implements TreeViewModel {
	public var categories(default, null):Array<String>;
	var roots:Array<String>;
	var children:Map<String, Array<String>>;
	var treeRevision:Int;

	public function new() {
		categories = [];
		roots = [];
		children = new Map();
		treeRevision = 0;
	}

	public function update(next:Array<String>):Void {
		if (next.join("\n") == categories.join("\n"))
			return;
		categories = next.copy();
		roots = [];
		children = new Map();
		for (category in categories) {
			var root = category.split("/")[0];
			if (roots.indexOf(root) < 0) {
				roots.push(root);
				var empty:Array<String> = [];
				children.set(root, empty);
			}
			if (category != root)
				children.get(root).push(category);
		}
		treeRevision++;
	}

	public function groups():Array<String>
		return roots.copy();

	/** The category a tree key stands for: itself, or a group's first category. */
	public function categoryFor(key:String):Null<String> {
		if (categories.indexOf(key) >= 0)
			return key;
		var under = children.get(key);
		return under == null || under.length == 0 ? null : under[0];
	}

	public function rootCount():Int
		return roots.length;

	public function rootRange(start:Int, count:Int):Array<TreeRootMetadata> {
		var result:Array<TreeRootMetadata> = [];
		var first = start < 0 ? 0 : start;
		var last = Std.int(Math.min(roots.length, first + count));
		for (index in first...last)
			result.push(new TreeRootMetadata(roots[index], true));
		return result;
	}

	public function rootKeyAt(index:Int):String {
		if (index < 0 || index >= roots.length)
			throw "Settings tree root index is out of range";
		return roots[index];
	}

	public function childCount(parentKey:String):Int {
		var under = children.get(parentKey);
		return under == null ? 0 : under.length;
	}

	public function childKeyAt(parentKey:String, index:Int):String {
		var under = children.get(parentKey);
		if (under == null || index < 0 || index >= under.length)
			throw "Settings tree child index is out of range";
		return under[index];
	}

	public function initiallyExpanded(_key:String):Bool
		return true;

	public function estimatedExtent():Float
		return 28.0;

	public function extentIsUniform():Bool
		return true;

	public function extentAt(_key:String):Float
		return 28.0;

	public function buildItem(key:String):View
		return new Text(SettingsCatalog.labelOf(key));

	public function revision():Int
		return treeRevision;
}
