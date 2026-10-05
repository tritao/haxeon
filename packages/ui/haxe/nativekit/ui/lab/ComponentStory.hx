package nativekit.ui.lab;

import nativekit.ui.core.View;

/** One stable, independently renderable component development case. */
class ComponentStory {
	public final id:String;
	public final title:String;
	public final group:String;
	public final description:String;
	final factory:Void->View;

	public function new(id:String, title:String, group:String, description:String,
			factory:Void->View) {
		if (id == null || id.length == 0 || factory == null)
			throw "Component stories require a stable ID and view factory";
		this.id = id;
		this.title = title == null ? id : title;
		this.group = group == null ? "Other" : group;
		this.description = description == null ? "" : description;
		this.factory = factory;
	}

	public function build():View return factory();
}
