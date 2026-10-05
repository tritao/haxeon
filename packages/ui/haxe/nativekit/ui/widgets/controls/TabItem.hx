package nativekit.ui.widgets.controls;

import nativekit.ui.icons.IconName;
import nativekit.ui.core.View;

/** One stable tab key, accessible label, and lazily built page. */
class TabItem {
	public final key:String;
	public final label:String;
	public final displayLabel:Null<String>;
	public final content:View;
	public final enabled:Bool;
	public final icon:Null<IconName>;
	/** Optional decorative view used in place of the standard icon. */
	public var badgeCount:Int = 0;
	public var iconView:Null<View>;
	/** Optional close action; the header reserves a hover-revealed close target. */
	public var onClose:Null<Void->Void>;

	public function new(key:String, label:String, content:View, enabled:Bool = true,
			?icon:IconName, ?displayLabel:String) {
		if (key == null || key.length == 0 || content == null)
			throw "Tabs require stable keys and content views";
		this.key = key;
		this.label = label == null ? "" : label;
		this.displayLabel = displayLabel;
		this.content = content;
		this.enabled = enabled;
		this.icon = icon;
	}
}
