package haxeon.agent;

class Message {
	public final role:Role;
	public final content:Array<ContentBlock>;

	public function new(role:Role, content:Array<ContentBlock>) {
		this.role = role;
		this.content = content;
	}

	public static function user(text:String):Message
		return new Message(User, [Text(text)]);

	public function text():String {
		var parts:Array<String> = [];
		for (block in content)
			switch block {
				case Text(text):
					parts.push(text);
				default:
			}
		return parts.join("");
	}

	public function toolUses():Array<ToolCall> {
		var calls:Array<ToolCall> = [];
		for (block in content)
			switch block {
				case ToolUse(id, name, inputJson):
					calls.push(new ToolCall(id, name, inputJson));
				default:
			}
		return calls;
	}

	public function toJson():String {
		var blocks:Array<String> = [];
		for (block in content)
			blocks.push(switch block {
				case Text(text):
					JsonWriter.object([JsonWriter.stringField("type", "text"), JsonWriter.stringField("text", text)]);
				case ToolUse(id, name, inputJson):
					JsonWriter.object([
						JsonWriter.stringField("type", "tool_use"),
						JsonWriter.stringField("id", id),
						JsonWriter.stringField("name", name),
						JsonWriter.field("input", inputJson == "" ? "{}" : inputJson)
					]);
				case ToolOutput(id, content, isError):
					JsonWriter.object([
						JsonWriter.stringField("type", "tool_result"),
						JsonWriter.stringField("tool_use_id", id),
						JsonWriter.stringField("content", content),
						JsonWriter.field("is_error", isError ? "true" : "false")
					]);
			});
		return JsonWriter.object([
			JsonWriter.stringField("role", role == User ? "user" : "assistant"),
			JsonWriter.field("content", JsonWriter.array(blocks))
		]);
	}

	/** Restores one message from `toJson`; null when the shape is not recognised. */
	public static function fromJson(json:JsonObject):Null<Message> {
		var roleName = json.string("role");
		if (roleName != "user" && roleName != "assistant")
			return null;
		var blocks:Array<ContentBlock> = [];
		for (item in json.objects("content")) {
			switch item.string("type") {
				case "text":
					blocks.push(Text(item.string("text")));
				case "tool_use":
					var input = item.object("input");
					blocks.push(ToolUse(item.string("id"), item.string("name"), input == null ? "{}" : input.toString()));
				case "tool_result":
					blocks.push(ToolOutput(item.string("tool_use_id"), item.string("content"), item.bool("is_error")));
				default:
					return null;
			}
		}
		return new Message(roleName == "user" ? User : Assistant, blocks);
	}
}
