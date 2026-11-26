package haxeon.ui.lab;

/** Ordered story collection shared by interactive and deterministic hosts. */
class ComponentStoryRegistry {
	final stories:Array<ComponentStory> = [];
	final byId:Map<String, ComponentStory> = new Map();

	/** An empty registry. */
	public function new() {}

	/** Adds `story`. Throws when its id is taken. Returns this registry. */
	public function register(story:ComponentStory):ComponentStoryRegistry {
		if (story == null || byId.exists(story.id))
			throw "Component story IDs must be unique";
		stories.push(story);
		byId.set(story.id, story);
		return this;
	}

	/** The story `id`, or null. */
	public function get(id:String):Null<ComponentStory> return byId.get(id);

	/** A copy of the stories, in the order they were registered. */
	public function all():Array<ComponentStory> return stories.copy();
}
