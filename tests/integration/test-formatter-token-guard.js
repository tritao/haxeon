const assert = require('assert');
const fs = require('fs');
const path = require('path');
const {spawnSync} = require('child_process');
const {checkedWriter} = require('../../scripts/format-external.js');
const guardPath = process.argv[2];
const directory = process.argv[3];
const {verify} = require(guardPath).FormatterTokenGuard;
const file = path.join(directory, 'known-bad.hx');
const source = 'function f(a:Int,b:Int):Int return a + ++b;\n';
const bad = 'function f(a:Int,b:Int):Int return a +++ b;\n';
for (const check of [false, true]) {
  fs.writeFileSync(file, source);
  const writer = checkedWriter(fs.readFileSync, fs.writeFileSync, verify, check,
    () => assert.fail('A token mismatch must fail before reporting a formatting difference'));
  assert.throws(() => writer(file, bad), error => {
    const message = String(error);
    return message.includes(file) && /at token \d+: expected Plus "\+", got Increment "\+\+"/.test(message);
  });
  assert.strictEqual(fs.readFileSync(file, 'utf8'), source, 'Rejected output overwrote the source');
}
verify(file, source, '// moved comment\nfunction f(a:Int, b:Int):Int return a + ++b;\n');
for (const [input, output] of [
  ['#if feature\nvar x = 1;\n#else\nvar x = 2;\n#end\n', '#if feature\nvar x = 3;\n#else\nvar x = 2;\n#end\n'],
  ['#if feature\nvar x = 1;\n#end\n', 'if feature\nvar x = 1;\n#end\n'],
  ['var x = "before";', 'var x = "after";'],
  ['var x = "before";', 'var x = "unterminated'],
]) {
  assert.throws(() => verify(file, input, output), error => String(error).includes(file) && /at token \d+/.test(String(error)));
}
verify(file, '#if feature\nvar x=1;\n#else\nvar x=2;\n#end\n',
  '#if  feature\nvar x = 1;\n#else\nvar x = 2;\n#end\n');
const runner = path.resolve(__dirname, '../../scripts/format-external.js');
for (const check of [true, false]) {
  fs.writeFileSync(file, source);
  const result = spawnSync(process.execPath, [runner, guardPath, '-s', file, ...(check ? ['--check'] : [])], {encoding: 'utf8'});
  assert.strictEqual(result.status, check ? 1 : 0, result.stdout + result.stderr);
  const after = fs.readFileSync(file, 'utf8');
  if (check) assert.strictEqual(after, source, '--check wrote the file');
  else verify(file, source, after);
}
// The pinned formatter really produces this token-changing rewrite. Exercise
// its actual process and write path, not only the injected bad-output unit case.
const genericSource = 'class Test { var items:Array<Int>=[]; }\n';
for (const check of [true, false]) {
  fs.writeFileSync(file, genericSource);
  const result = spawnSync(process.execPath, [runner, guardPath, '-s', file, ...(check ? ['--check'] : [])], {encoding: 'utf8'});
  assert.strictEqual(result.status, 2, result.stdout + result.stderr);
  assert(result.stderr.includes(file) && /at token \d+: expected GreaterEqual ">=", got Greater ">"/.test(result.stderr), result.stderr);
  assert.strictEqual(fs.readFileSync(file, 'utf8'), genericSource, 'The real formatter wrote a token-changing result');
}
console.log('PASS: known-bad formatter output is refused before writing in format/check modes, with filename and first differing token');
