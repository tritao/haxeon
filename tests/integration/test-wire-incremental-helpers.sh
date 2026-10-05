#!/usr/bin/env bash
set -euo pipefail
repo_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
project_dir=$(mktemp -d "${TMPDIR:-/tmp}/haxeon-wire-incremental.XXXXXX")
trap 'rm -rf -- "$project_dir"' EXIT
mkdir -p "$project_dir/src"
cat > "$project_dir/haxeon.json" <<'JSON'
{"version":1,"package":{"name":"wire-incremental-test"},"entry":"Main","sourceRoots":["src"],"target":"host","outputDir":"build"}
JSON
cat > "$project_dir/src/Protocol.hx" <<'HX'
import haxe.io.Bytes;
import haxeon.wire.MessagePack;
import haxeon.wire.JsonWire;
@:wire typedef Detail = { @:id(1) var code:Int; }
@:wire enum Envelope { @:id(1) Value(detail:Detail); }
class Protocol {
 public static function encode(value:Envelope):Bytes return MessagePack.encode(value);
 public static function decode(bytes:Bytes):Envelope return MessagePack.decode(bytes);
 public static function encodeJson(value:Envelope):String return JsonWire.encode(value);
 public static function decodeJson(text:String):Envelope return JsonWire.decode(text);
}
HX
cat > "$project_dir/src/Main.hx" <<'HX'
import Protocol.Envelope;
import haxeon.wire.MessagePack;
import haxeon.wire.JsonWire;
@:wire typedef Answer = { @:id(1) var result:String; }
class Main {
 static function main():Void {
  var answer:Answer = MessagePack.decode(MessagePack.encode(({result: "ok"}:Answer)));
  var diagnosticAnswer:Answer = JsonWire.decode(JsonWire.encode(answer));
  var decoded = Protocol.decode(Protocol.encode(Value({code: 42})));
  switch decoded { case Value(detail): if (detail.code != 42 || answer.result != "ok") throw "bad round trip"; }
  var diagnostic = Protocol.decodeJson(Protocol.encodeJson(Value({code: 43})));
  switch diagnostic { case Value(detail): if (detail.code != 43 || diagnosticAnswer.result != "ok") throw "bad JSON round trip"; }
  Sys.println("PASS: first generation");
 }
}
HX
"$repo_dir/scripts/haxeon" run --project "$project_dir/haxeon.json" > "$project_dir/first.log" 2>&1 || { cat "$project_dir/first.log"; exit 1; }
python3 - "$project_dir/src/Main.hx" <<'PY'
import pathlib, sys
path = pathlib.Path(sys.argv[1])
path.write_text(path.read_text().replace('first generation', 'second generation'))
PY
"$repo_dir/scripts/haxeon" run --project "$project_dir/haxeon.json" > "$project_dir/second.log" 2>&1 || { cat "$project_dir/second.log"; exit 1; }
rg -q 'PASS: second generation' "$project_dir/second.log"
echo 'PASS: persisted incremental builds retain nested wire helpers across caller edits'
