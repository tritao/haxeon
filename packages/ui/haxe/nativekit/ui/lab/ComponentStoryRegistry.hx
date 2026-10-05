package nativekit.ui.lab;

/** Ordered story collection shared by interactive and deterministic hosts. */
class ComponentStoryRegistry {
	final stories:Array<ComponentStory> = [];
	final byId:Map<String, ComponentStory> = new Map();

	public function new() {}

	public function register(story:ComponentStory):ComponentStoryRegistry {
		if (story == null || byId.exists(story.id))
			throw "Component story IDs must be unique";
		stories.push(story);
		byId.set(story.id, story);
		return this;
	}

	public function get(id:String):Null<ComponentStory> return byId.get(id);

	public function all():Array<ComponentStory> return stories.copy();
}
