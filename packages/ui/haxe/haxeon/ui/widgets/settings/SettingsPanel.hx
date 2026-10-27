package haxeon.ui.widgets.settings;

import haxeon.ui.LayoutAlignmentY;
import haxeon.ui.LayoutAxis;
import haxeon.ui.LayoutDirection;
import haxeon.ui.LayoutStyle;
import haxeon.ui.Insets;
import haxeon.ui.core.BuildContext;
import haxeon.ui.core.RenderNode;
import haxeon.ui.core.View;
import haxeon.ui.settings.SettingsCatalog;
import haxeon.ui.settings.SettingsStore;
import haxeon.ui.widgets.KeyedView;
import haxeon.ui.widgets.collections.TreeRootMetadata;
import haxeon.ui.widgets.collections.TreeView;
import haxeon.ui.widgets.collections.TreeViewModel;
import haxeon.ui.widgets.controls.SearchField;
import haxeon.ui.widgets.controls.Toggle;
import haxeon.ui.widgets.layout.Column;
import haxeon.ui.widgets.layout.Row;
import haxeon.ui.widgets.layout.SplitSide;
import haxeon.ui.widgets.layout.SplitView;
import haxeon.ui.widgets.layout.SplitViewOptions;
import haxeon.ui.widgets.properties.PropertyInspector;
import haxeon.ui.widgets.text.Text;

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
	public var modifiedOnly(default, null):Bool = false;
	var storeRevision:Int = -1;
	var visibleCounts:Map<String, Int> = new Map();
	/** The category shown on the right, or null when nothing matches. */
	public var selectedCategory(default, null):Null<String>;
	public var onChanged:Null<Void->Void>;
	public var treeWidth:Float;
	public var labelWidth:Float;
	public final editorRegistry = new haxeon.ui.properties.PropertyEditorRegistry();
	public var compact:Bool = false;

	final treeModel:SettingsTreeModel;
	var inspector:Null<PropertyInspector>;
	var inspectorKey:String;

	public function new(key:String, store:SettingsStore, ?onChanged:Void->Void) {
		if (key == null || key.length == 0)
			throw "Settings panels require a stable key";
		this.key = key;
		catalog = new SettingsCatalog(store);
		filter = "";
		showAdvanced = store.getState(key + ":advanced") == true;
		selectedCategory = null;
		this.onChanged = onChanged;
		treeWidth = 220.0;
		labelWidth = 260.0;
		treeModel = new SettingsTreeModel();
		inspector = null;
		inspectorKey = "";
		refresh();
		var saved:Dynamic = store.getState(key + ":category");
		if (Std.isOfType(saved, String)) select(cast saved);
	}

	public function hasUnsavedChanges():Bool return false;
	public function discardUnsavedChanges():Void {}

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
		catalog.store.setState(key + ":advanced", value);
		refresh();
	}

	public function setModifiedOnly(value:Bool):Void {
		if (modifiedOnly == value) return;
		modifiedOnly = value;
		refresh();
	}

	/** Selects a category, or the first category under a tree group such as "interface". */
	public function select(key:String):Void {
		var target = treeModel.categoryFor(key);
		if (target == null || target == selectedCategory)
			return;
		selectedCategory = target;
		catalog.store.setState(this.key + ":category", target);
		changed();
	}

	/** Categories the tree lists for the current filter, in order. */
	public function categories():Array<String>
		return treeModel.categories.copy();

	/** The inspector for the selected category; rebuilt only when the category, filter or Advanced switch changes. */
	public function categoryCount(category:String):Int {
		if (storeRevision != catalog.store.revision) refresh();
		var count = visibleCounts.get(category);
		return count == null ? 0 : count;
	}

	public function invalidateInspector():Void {
		inspector = null;
	}

	public function currentInspector():Null<PropertyInspector> {
		if (storeRevision != catalog.store.revision) refresh();
		if (selectedCategory == null)
			return null;
		var searching = StringTools.trim(filter).length > 0;
		var nextKey = selectedCategory + "|" + filter + "|" + showAdvanced + "|" + modifiedOnly + "|" + (modifiedOnly ? catalog.store.revision : 0);
		if (inspector == null || inspectorKey != nextKey) {
			var sections = [];
			for (category in searching ? categories() : [selectedCategory]) {
				for (section in catalog.sections(category, filter, showAdvanced, modifiedOnly)) {
					sections.push(searching ? new haxeon.ui.properties.PropertyInspectorSection(section.id,
						[for (part in category.split("/")) SettingsCatalog.labelOf(part)].join(" › ") + " — " + section.label,
						section.descriptors) : section);
				}
			}
			inspector = new PropertyInspector(key + ":inspector:" + selectedCategory, null, null, editorRegistry,
				sections, null,
				SettingsCatalog.labelOf(selectedCategory) + " settings");
			inspectorKey = nextKey;
		}
		return inspector;
	}

	public function build(context:BuildContext):RenderNode {
		if (storeRevision != catalog.store.revision) refresh();
		var headerStyle = new LayoutStyle();
		headerStyle.width = LayoutAxis.grow();
		headerStyle.height = LayoutAxis.fit();
		headerStyle.direction = LayoutDirection.LeftToRight;
		headerStyle.childAlignY = LayoutAlignmentY.Center;
		headerStyle.childGap = 12.0;
		var searchStyle = new LayoutStyle();
		searchStyle.width = LayoutAxis.grow();
		var headerChildren:Array<KeyedView> = [
			new KeyedView("filter", new SearchField(key + ":filter", filter, setFilter, searchStyle, "Filter Settings")),
			new KeyedView("modified", new Toggle(key + ":modified", "Modified only", modifiedOnly, setModifiedOnly)),
			new KeyedView("advanced", new Toggle(key + ":advanced", "Advanced Settings", showAdvanced, setShowAdvanced))
		];
		if (compact) headerStyle.direction = LayoutDirection.TopToBottom;
		var header:View = compact ? new Column(key + ":header", headerChildren, headerStyle) : new Row(key + ":header", headerChildren, headerStyle);

		var treeStyle = fill();
		var tree = new TreeView(key + ":tree:" + treeModel.revision(), treeModel, treeStyle, null, 400.0,
			selectedCategory, treeModel.groups(), select);

		var inspectorView:View = null;
		var current = currentInspector();
		if (current == null) {
			inspectorView = new Text(filter.length == 0 ? (modifiedOnly ? "No modified settings." : "No settings.") : "No settings match \"" + filter + "\".");
		} else {
			current.labelWidth = compact ? 100 : labelWidth;
			current.stackedRows = compact;
			current.searchQuery = filter;
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
		var children:Array<KeyedView> = [
			new KeyedView("header", header),
			new KeyedView("body", compact ? compactBody(inspectorView) : split),
			new KeyedView("status", new Text(catalog.store.lastError != null ? catalog.store.lastError :
				(hasUnsavedChanges() ? "Unsaved list changes · Apply each list to save" : (current == null ? "0 settings" : Std.string(current.descriptors.length) + " settings") + " · Changes save automatically")))
		];
		var restart = catalog.store.restartChanges();
		if (restart.length > 0) {
			var summaryStyle = new LayoutStyle(); summaryStyle.width = LayoutAxis.grow();
			children.push(new KeyedView("restart-summary", new Text("Restart required for " + restart.length +
				(restart.length == 1 ? " changed setting: " : " changed settings: ") + [for (setting in restart) setting.label].join(", "),
				summaryStyle, null, haxeon.ui.core.TextStyleOverride.paragraph(haxeon.ui.TextWrap.WordCharacter))));
		}
		return new Column(key, children, columnStyle).build(context);
	}

	function compactBody(inspector:View):View {
		var options = [for (category in categories()) new haxeon.ui.widgets.controls.SelectOption(category,
			[for (part in category.split("/")) SettingsCatalog.labelOf(part)].join(" › ") + " (" + categoryCount(category) + ")", category)];
		var children:Array<KeyedView> = [];
		if (options.length > 0) children.push(new KeyedView("category", new haxeon.ui.widgets.controls.Select(
			key + ":category", options, selectedCategory, select)));
		children.push(new KeyedView("inspector", inspector));
		var style = fill(); style.childGap = 8;
		return new Column(key + ":compact", children, style);
	}

	/** Recomputes the tree after the filter or Advanced switch changed, keeping the selection when it still matches. */
	function refresh():Void {
		storeRevision = catalog.store.revision;
		visibleCounts = catalog.categoryCounts(filter, showAdvanced, modifiedOnly);
		treeModel.update(catalog.categories(filter, showAdvanced, modifiedOnly), visibleCounts, filter);
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
	var counts:Map<String, Int> = new Map();
	var query:String = "";
	var contentKey:String = "";

	public function new() {
		categories = [];
		roots = [];
		children = new Map();
		treeRevision = 0;
	}

	public function update(next:Array<String>, nextCounts:Map<String, Int>, filter:String):Void {
		var nextKey = [for (category in next) category + ":" + nextCounts.get(category)].join("\n") + "|" + filter;
		if (nextKey == contentKey)
			return;
		contentKey = nextKey;
		counts = nextCounts;
		query = filter;
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

	public function buildItem(key:String):View {
		var count = 0;
		for (category in categories) if (category == key || StringTools.startsWith(category, key + "/")) {
			var value = counts.get(category);
			if (value != null) count += value;
		}
		return new haxeon.ui.widgets.text.HighlightedText(SettingsCatalog.labelOf(key) + " (" + count + ")", query);
	}

	public function revision():Int
		return treeRevision;
}
