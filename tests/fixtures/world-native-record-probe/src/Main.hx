class Main {
	static function main():Int {
		return sizeof<Transform>() == 24
			&& alignof<Transform>() == 8
			&& offsetof<Transform>("x") == 0
			&& offsetof<Transform>("y") == 8
			&& offsetof<Transform>("z") == 16 ? 42 : 1;
	}
}
