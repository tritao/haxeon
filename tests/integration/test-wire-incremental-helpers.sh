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

cat > "$project_dir/src/Main.hx" <<'HX'
import Schema.Envelope;
import Schema.Task;
import Schema.Wrapped;
import haxeon.rpc.RpcMethod;
import haxeon.wire.JsonWire;
import haxeon.wire.MessagePack;

function main():Void {
 var task:Task = {title: "Buy milk", priority: 7};
 var envelope:Envelope = Value(task);
 var wrapped:Wrapped = {task: task};
 var method:RpcMethod<Wrapped, Task> = RpcMethod.wire(100);
 var json = JsonWire.encode(envelope);
 var bytes = MessagePack.encode(envelope);
 var decodedJson:Envelope = JsonWire.decode(json);
 var decodedBytes:Envelope = MessagePack.decode(bytes);
 Sys.println(JsonWire.encode(decodedJson));
 Sys.println(MessagePack.encode(decodedBytes).toHex());
 Sys.println(method.encodeRequest(method.decodeRequest(method.encodeRequest(wrapped))).toHex());
 Sys.println(method.encodeResponse(method.decodeResponse(method.encodeResponse(task))).toHex());
}
HX

write_schema() {
 {
  printf '%s\n' "$1"
  printf '%s\n' 'enum Envelope { Value(task:Task); }' 'typedef Wrapped = {task:Task};'
 } > "$project_dir/src/Schema.hx"
}

run_schema() {
 local server=1
 if [[ $1 == cold ]]; then
  server=0
 fi
 HAXEON_COMPILER_SERVER="$server" HAXEON_COMPILER_SESSION_DIR="$project_dir/session" \
  "$repo_dir/scripts/haxeon" run --quiet --project "$project_dir/haxeon.json" > "$project_dir/$1.out"
}

compare_builds() {
 local change=$1
 run_schema warm
 mv "$project_dir/build" "$project_dir/warm-build"
 run_schema cold
 diff -u "$project_dir/cold.out" "$project_dir/warm.out"
 rm -rf -- "$project_dir/build"
 mv "$project_dir/warm-build" "$project_dir/build"
 if cmp -s "$project_dir/previous.out" "$project_dir/warm.out"; then
  echo "FAIL: $change did not change the wire output" >&2
  exit 1
 fi
 cp "$project_dir/warm.out" "$project_dir/previous.out"
 echo "PASS: $change agrees with a cold build"
}

numbered='@:wire typedef Task = { @:id(1) var title:String; @:id(2) var priority:Int; }'
named='typedef Task = {title:String, priority:Int};'
write_schema "$numbered"
run_schema warm
cp "$project_dir/warm.out" "$project_dir/previous.out"

write_schema "$named"
compare_builds 'removing wire annotations'
write_schema "$numbered"
compare_builds 'adding wire annotations'
write_schema '@:wire typedef Task = { @:id(3) var title:String; @:id(2) var priority:Int; }'
compare_builds 'renumbering a wire field'

write_schema "$named"
run_schema warm
cp "$project_dir/warm.out" "$project_dir/previous.out"
write_schema 'typedef Task = {priority:Int, title:String};'
compare_builds 'reordering named wire fields'
write_schema 'typedef Task = {priority:Float, title:String};'
compare_builds 'changing a nested wire field type'

cat > "$project_dir/src/Main.hx" <<'HX'
import haxeon.wire.JsonWire;

typedef First = {first:Int};

function encodeFirst():String return JsonWire.encode(({first: 1}:First));

function main():Void {
 Sys.println(encodeFirst());
 Sys.println(Second.encode());
 Sys.println(Unserialized.marker());
}
HX
write_second() {
 cat > "$project_dir/src/Second.hx" <<HX
import haxeon.wire.JsonWire;

typedef Payload = {$1};

class Second {
 public static function encode():String return JsonWire.encode(({value: 2, label: "$2"}:Payload));
}
HX
}
write_second 'value:Int, label:String' 'two'

write_unserialized() {
 {
  printf '%s\n' 'class Unserialized {' "$@" ' public static function marker():Int return 3;' '}'
 } > "$project_dir/src/Unserialized.hx"
}
write_unserialized ' var x:Int;' ' var y:String;'

build_with_stats() {
 HAXEON_COMPILER_SERVER=1 HAXEON_COMPILER_SESSION_DIR="$project_dir/session" \
  "$repo_dir/scripts/haxeon" build --verbosity=detailed --project "$project_dir/haxeon.json" \
  > "$project_dir/stats.log" 2>&1 || { cat "$project_dir/stats.log"; exit 1; }
}

expect_retyped() {
 local expected=$1
 rg -q 'reusing compiler session' "$project_dir/stats.log" &&
  rg -q "compiler: [0-9]+ ms, $expected functions retyped" "$project_dir/stats.log" ||
  { cat "$project_dir/stats.log"; exit 1; }
}

build_with_stats
write_unserialized ' var y:String;' ' var x:Int;'
build_with_stats
expect_retyped 0
echo 'PASS: reordering an unserialized class leaves codec users cached'

# The worker count includes generated helpers. A body-only edit measures the cost of rebuilding Second.encode and its codec.
write_second 'value:Int, label:String' 'second'
build_with_stats
second_retyped=$(rg -o --replace '$1' 'compiler: [0-9]+ ms, ([1-9][0-9]*) functions retyped' "$project_dir/stats.log")
expect_retyped "$second_retyped"

write_second 'label:String, value:Int' 'second'
build_with_stats
expect_retyped "$second_retyped"
run_schema warm
rg -Fxq '{"version":1,"value":{"first":1}}' "$project_dir/warm.out" &&
 rg -Fxq '{"version":1,"value":{"label":"second","value":2}}' "$project_dir/warm.out" ||
 { cat "$project_dir/warm.out"; exit 1; }
echo 'PASS: reordering one wire typedef only retypes its own codec user'
