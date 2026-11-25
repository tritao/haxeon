package haxeon.ui.widgets.controls;

import haxeon.ui.core.View;
import haxeon.ui.icons.IconName;

/** One stable tab key, accessible label, and lazily built page. */
class TabItem {
	/** Identifies the tab, as `Tabs.selectedKey` names it: required, and never empty. */
	public final key:String;

	/** The tab's name, which assistive technology announces, and its header text unless `displayLabel` is given. */
	public final label:String;

	/** Shorter header text, when the full `label` does not fit. */
	public final displayLabel:Null<String>;

	/** What the tab shows while selected. */
	public final content:View;

	/** Whether the tab can be selected. */
	public final enabled:Bool;

	/** An icon before the header text. */
	public final icon:Null<IconName>;

	/** A count shown in a badge on the header, such as unread items, when positive; it is announced with the name. */
	public var badgeCount:Int = 0;

	/** Optional decorative view used in place of the standard icon. */
	public var iconView:Null<View>;
	/** Optional close action; the header reserves a hover-revealed close target. */
	public var onClose:Null<Void->Void>;

	/** A tab named `label` showing `content`. Throws when `key` is empty or there is no content. */
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
