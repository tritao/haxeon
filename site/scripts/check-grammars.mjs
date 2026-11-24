import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import { mkdtemp, readFile, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { createHighlighter } from 'shiki';
import haxe from '../../extensions/vscode/syntaxes/haxe.tmLanguage.json' with { type: 'json' };
import hxi from '../../extensions/vscode/syntaxes/hxi.tmLanguage.json' with { type: 'json' };

const root = new URL('../../', import.meta.url);
const lexer = await readFile(new URL('src/compiler/syntax/Lexer.hx', root), 'utf8');
const keywordFunction = lexer.match(/static function keyword\(text:String\):TokenKind \{([\s\S]*?)\n\t\}/)?.[1];
assert.ok(keywordFunction, 'Could not locate Lexer.keyword()');
const lexerWords = [...keywordFunction.matchAll(/"([^"]+)"/g)].map(([, word]) => word);

// Parser recognizes these spellings while the lexer returns Identifier.
const contextualExamples = [
  '#abstract Example(Int) #from Int #to Int {}',
  'import pkg.Name #as Alias;',
  '#using pkg.Extension;',
  '#extern class Native {}',
  '#macro function expand() {}',
  '#override function run() {}',
  '#scoped var owned = #cast #null;',
  '#scoped /* ownership */ var other;',
  'var property(#get, #set);',
  'var property(#dynamic, #never);',
  '#sizeof<Int>() + #alignof<Int>() + #offsetof<Int>() + #typeInfo<Int>()',
];
const contextualWords = contextualExamples.flatMap(example =>
  [...example.matchAll(/#(\w+)/g)].map(([, word]) => word)
);

const highlighter = await createHighlighter({ themes: [], langs: [haxe, hxi] });
const wordScope = /^(keyword|storage|constant\.language|support\.type\.primitive)\./;
function scopeAt(tokens, offset) {
  return tokens.find(({ startIndex, endIndex }) => startIndex <= offset && offset < endIndex)?.scopes ?? [];
}

function checkHaxeKeywords() {
  const grammar = highlighter.getLanguage('haxe');
  const rules = [
    ...haxe.repository.keywords.patterns,
    ...haxe.repository['contextual-keywords'].patterns,
    haxe.repository.properties.patterns[0],
  ];
  const grammarWords = new Set(rules.flatMap(({ match }) => {
    const alternatives = match.match(/^\\b\(\?:([\w|]+)\)\\b/);
    assert.ok(alternatives, `Expected keyword alternatives in ${match}`);
    return alternatives[1].split('|');
  }));
  assert.deepEqual(grammarWords, new Set([...lexerWords, ...contextualWords]));

  const seen = new Set();
  for (const line of [...lexerWords, ...contextualExamples.map(example => example.replaceAll('#', ''))]) {
    const { tokens } = grammar.tokenizeLine(line);
    for (const { 0: word, index } of line.matchAll(/\b\w+\b/g)) {
      if (grammarWords.has(word)) {
        assert.ok(scopeAt(tokens, index).some(scope => wordScope.test(scope)), `Unscoped ${word} in ${line}`);
        seen.add(word);
      }
    }
  }
  assert.deepEqual(seen, grammarWords, 'Every keyword needs a tokenization example');
  const { tokens } = grammar.tokenizeLine('var scoped = scopedValue;');
  assert.ok(!scopeAt(tokens, 4).some(scope => wordScope.test(scope)), 'scoped is contextual');

  const sample = "var s = 'x: ${{x: 'inner'}.x} $s'; var pattern = ~/[a/b]\\//gi; #if flag defer f(); #end";
  const syntax = grammar.tokenizeLine(sample).tokens;
  for (const [fragment, scope] of [
    ["'inner'", 'string.quoted.single.haxe'],
    ['.x}', 'meta.interpolation.haxe'],
    ['$s', 'variable.other.interpolation.haxe'],
    ['[a/b]', 'constant.other.character-class.regexp.haxe'],
    ['#if', 'keyword.control.directive.haxe'],
    ['defer', 'keyword.control.haxe'],
  ]) {
    assert.ok(scopeAt(syntax, sample.indexOf(fragment)).includes(scope), `Expected ${scope} on ${fragment}`);
  }
}

const directory = await mkdtemp(join(tmpdir(), 'haxeon-grammars-'));
try {
  checkHaxeKeywords();

  const fixture = 'tests/ffi/import_fixture.h';
  const file = join(directory, 'import_fixture.hxi');
  execFileSync(fileURLToPath(new URL('scripts/haxeon', root)), [
    'ffi', 'import', '--target=x86_64-linux-gnu', '--include=tests/ffi', `--output=${file}`, fixture,
  ], { cwd: root, stdio: 'inherit' });

  const grammar = highlighter.getLanguage('hxi');
  const seen = new Set();
  let stack;
  for (const line of (await readFile(file, 'utf8')).split('\n')) {
    const { tokens, ruleStack } = grammar.tokenizeLine(line, stack);
    stack = ruleStack;
    if (tokens[0]?.scopes.some(scope => scope.startsWith('comment.'))) continue;
    for (const { 0: word, index } of line.matchAll(/(?<=^\s*)(?:interface|const|flags|enum|extern|struct|type|opaque|handle|callback)\b|(?<=(?:extern |= ))fn\b|\b(?:ptr|nullable|array|const)(?=<)|@[A-Za-z_]\w*/g)) {
      assert.ok(scopeAt(tokens, index).some(scope => wordScope.test(scope)), `Unscoped ${word} in ${line}`);
      seen.add(word);
    }
  }
  for (const word of ['interface', 'extern', 'fn', 'struct', 'enum', 'const', 'ptr', 'nullable', '@target']) {
    assert.ok(seen.has(word), `Generated fixture must exercise ${word}`);
  }
  console.log('Haxeon keywords and generated HXI tokenization verified');
} finally {
  highlighter.dispose();
  await rm(directory, { recursive: true, force: true });
}
