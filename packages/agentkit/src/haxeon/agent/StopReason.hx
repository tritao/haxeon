package haxeon.agent;

/** Why a model turn or a run ended. */
enum StopReason {
	/** The model finished. */
	EndTurn;

	/** The model called tools and waits for their results. */
	ToolCalls;

	/** The turn hit its token limit. */
	MaxTokens;

	/** The host aborted the run. */
	Aborted;

	/** Something failed, as `message` says. */
	Failed(message:String);
}
