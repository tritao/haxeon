/**
 * Cuts one method out of a class's source, from its declaration to the brace that closes it, one indent level removed.
 * A renamed or reshaped method fails the build instead of leaving stale code on a page.
 */
export function methodSource(source: string, name: string, file: string): string {
  const escaped = name.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
  const found = source.match(new RegExp(`^\\t(?:(?:public|private|static|override|inline) )*function ${escaped}\\([\\s\\S]*?^\\t\\}`, 'm'));
  if (!found) throw new Error(`Missing the method ${name} in ${file}`);
  return found[0].replace(/^\t/gm, '');
}
