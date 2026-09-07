package utest.ui;

import utest.Runner;

/** Enables the text report emitted by the synchronous Haxeon runner. */
class Report {
	public static function create(runner:Runner):Report {
		runner.displayResults = true;
		return new Report();
	}

	public function new() {}
}
