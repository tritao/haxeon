// Route genuine module-level Haxeon struct declarations to the built-in formatter.
// Embedded HXI/Haxe sources and comments must remain with the host-Haxe formatter.
const fs = require('fs');

function hasStructDeclaration(source) {
  let position = 0;
  function skipQuoted(quote) {
    position++;
    while (position < source.length) {
      const value = source[position++];
      if (value === '\\') position++;
      else if (quote === "'" && value === '$' && source[position] === '{') {
        position++;
        let depth = 1;
        while (position < source.length && depth > 0) {
          const token = nextToken();
          if (token === '{') depth++;
          if (token === '}') depth--;
        }
      } else if (value === quote) return;
    }
  }
  function nextToken() {
    while (position < source.length) {
      const value = source[position];
      if (/\s/.test(value)) { position++; continue; }
      if (source.startsWith('//', position)) {
        while (position < source.length && source[position] !== '\n') position++;
        continue;
      }
      if (source.startsWith('/*', position)) {
        const end = source.indexOf('*/', position + 2);
        position = end < 0 ? source.length : end + 2;
        continue;
      }
      if (value === '"' || value === "'") { skipQuoted(value); return '<literal>'; }
      if (source.startsWith('~/', position)) {
        position += 2;
        let inClass = false;
        while (position < source.length) {
          const character = source[position++];
          if (character === '\\') { position++; continue; }
          if (character === '[') inClass = true;
          if (character === ']') inClass = false;
          if (character === '/' && !inClass) break;
        }
        while (position < source.length && /[a-z]/i.test(source[position])) position++;
        return '<literal>';
      }
      if (/[A-Za-z_]/.test(value)) {
        const start = position++;
        while (position < source.length && /[A-Za-z0-9_]/.test(source[position])) position++;
        return source.slice(start, position);
      }
      position++;
      return value;
    }
    return '';
  }
  let depth = 0;
  while (position < source.length) {
    const token = nextToken();
    if (token === 'struct' && depth === 0 && /^[A-Za-z_][A-Za-z0-9_]*$/.test(nextToken())) return true;
    if (token === '{') depth++;
    if (token === '}') depth--;
  }
  return false;
}

module.exports = {hasStructDeclaration};
if (require.main === module)
  for (const file of process.argv.slice(2))
    console.log(`${hasStructDeclaration(fs.readFileSync(file, 'utf8')) ? 'struct' : 'external'}\t${file}`);
