package haxeon.agent;

enum StopReason {
	EndTurn;
	ToolCalls;
	MaxTokens;
	Aborted;
	Failed(message:String);
}
