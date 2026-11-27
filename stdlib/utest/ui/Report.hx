package utest.ui;

import utest.Runner;

/** Enables the text report emitted by the synchronous Haxeon runner. */
class Report {
	/** Makes `runner` print its results, and returns the report. */
	public static function create(runner:Runner):Report {
		runner.displayResults = true;
		return new Report();
	}

	/** A report; `create` is what turns printing on. */
	public function new() {}
}
