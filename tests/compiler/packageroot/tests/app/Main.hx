package app;

import app.Runner;

class Main {
	static function check(scene:Runner.Scene):Int
		return scene.value + 1;

	static function main():Int
		return check(Runner.load());
}
