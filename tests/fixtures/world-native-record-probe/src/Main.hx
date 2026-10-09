import world.Entity;

class Main {
	static function main():Int {
		var entity = new Entity(-9, 214),
			absent:Null<Entity> = null,
			present:Null<Entity> = entity;
		return sizeof<Transform>() == 24
			&& alignof<Transform>() == 8
			&& offsetof<Transform>("x") == 0
			&& offsetof<Transform>("y") == 8
			&& offsetof<Transform>("z") == 16
			&& sizeof<Entity>() == 8
			&& alignof<Entity>() == 4
			&& offsetof<Entity>("slot") == 0
			&& offsetof<Entity>("generation") == 4
			&& entity.slot == -9
			&& entity.generation == 214
			&& entity.same(present)
			&& absent == null
			&& present != null ? 42 : 1;
	}
}
