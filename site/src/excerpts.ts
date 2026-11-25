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

export interface ListedPage {
  title: string;
  /** The linked file, relative to the README. */
  page: string;
}

/** The pages a docs README lists, in its order: its `1. [Title](page.md)` or `- [Title](page.md)` lines. */
export function listedPages(markdown: string, file: string): ListedPage[] {
  const pages = [...markdown.matchAll(/^(?:\d+\.|-) \[([^\]]+)\]\(([^)]+\.md)\)$/gm)].map(([, title, page]) => ({ title, page }));
  if (!pages.length) throw new Error(`${file} lists no pages`);
  return pages;
}

/** Pairs each listed page with its summary; a page without one, or a summary for an unlisted page, fails the build. */
export function withSummaries(pages: ListedPage[], summaries: Record<string, string>, file: string) {
  const missing = pages.filter(({ page }) => !(page in summaries)).map(({ page }) => page);
  const unlisted = Object.keys(summaries).filter((page) => !pages.some((listed) => listed.page === page));
  if (missing.length || unlisted.length)
    throw new Error(`${file}: no summary for [${missing.join(', ')}], summaries for unlisted [${unlisted.join(', ')}]`);
  return pages.map((listed) => ({ ...listed, text: summaries[listed.page] }));
}
