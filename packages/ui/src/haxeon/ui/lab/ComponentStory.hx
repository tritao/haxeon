package haxeon.ui.lab;

import haxeon.ui.core.View;

/** One stable, independently renderable component development case. */
class ComponentStory {
	/** A stable identifier, used to select it. */
	public final id:String;

	/** Its name in the story list. */
	public final title:String;

	/** The group it is listed under. */
	public final group:String;

	/** What it shows. */
	public final description:String;
	final factory:Void->View;

	/** A story whose view `factory` builds. */
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

	/** Builds its view. */
	public function build():View return factory();
}
