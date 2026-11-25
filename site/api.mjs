// The API reference of the first-party packages, from what `haxeon doc` describes (scripts/build-api.sh writes
// generated/api/<directory>.json, which the `api` content collection loads; docs/design/API_MODEL.md is the format). A
// package has an overview page, and a page per Haxe package of its API, each type with its members.
import { apiBase, apiPackages, repositorySource } from './docs.mjs';

export { apiBase, apiPackages };

const haxePackageOf = (modulePath) => modulePath.split('.').slice(0, -1).join('.');
const shortName = (path) => path.slice(path.lastIndexOf('.') + 1);

/** The Haxe packages of a package's API, each with its types and its modules' own functions and variables. */
export function haxePackages(model) {
  const described = new Set(model.described);
  const groups = new Map();
  const group = (name) => {
    if (!groups.has(name)) groups.set(name, { name, types: [], modules: [] });
    return groups.get(name);
  };
  for (const type of model.types) if (described.has(type.module)) group(haxePackageOf(type.module)).types.push(type);
  for (const module of model.modules)
    if (described.has(module.path) && module.members.length > 0) group(haxePackageOf(module.path)).modules.push(module);
  return [...groups.values()].sort((left, right) => left.name.localeCompare(right.name));
}

export const haxePackageSlug = (name) => (name === '' ? '_' : name);
export const haxePackageUrl = (directory, name) => `${apiBase}${directory}/${haxePackageSlug(name)}/`;
export const typeAnchor = (path) => shortName(path);

/**
 * Where each described type is, over every package `entries` (the `api` collection) describes, and which directory holds
 * each package: a type name links to its page wherever it appears, and a declaration to its source.
 */
export function apiIndex(entries) {
  const types = new Map();
  const directories = new Map();
  for (const { directory, model } of entries) {
    if (!model) continue;
    const described = new Set(model.described);
    for (const type of model.types) {
      if (!described.has(type.module)) continue;
      types.set(type.path, `${haxePackageUrl(directory, haxePackageOf(type.module))}#${typeAnchor(type.path)}`);
      if (type.package) directories.set(type.package, directory);
    }
  }
  return { types, directories };
}

const escape = (text) =>
  String(text).replaceAll('&', '&amp;').replaceAll('<', '&lt;').replaceAll('>', '&gt;').replaceAll('"', '&quot;');

/** A type as HTML, as the source writes it, each named type a link to its page when the reference has one. */
export function typeHtml(type, index) {
  switch (type.kind) {
    case 'named':
    case 'builtin': {
      const name = shortName(type.path);
      const url = type.kind === 'named' ? index.types.get(type.path) : null;
      const head = url
        ? `<a href="${escape(url)}" title="${escape(type.path)}">${escape(name)}</a>`
        : `<span title="${escape(type.path)}">${escape(name)}</span>`;
      return type.arguments.length === 0
        ? head
        : `${head}&lt;${type.arguments.map((argument) => typeHtml(argument, index)).join(', ')}&gt;`;
    }
    case 'parameter':
      return escape(type.name);
    case 'function': {
      const parts = type.arguments.map((argument, i) => (type.optional[i] ? '?' : '') + typeHtml(argument, index));
      return `(${parts.join(', ')}) -&gt; ${typeHtml(type.result, index)}`;
    }
    case 'anonymous':
      return `{ ${type.fields
        .map((field) => `${field.optional ? '?' : ''}${field.isFinal ? 'final ' : ''}${escape(field.name)}:${typeHtml(field.type, index)}`)
        .join(', ')} }`;
    case 'anonymousRef':
      return '…';
    default:
      return escape(type.name);
  }
}

const parametersHtml = (parameters, index) =>
  parameters.length === 0
    ? ''
    : `&lt;${parameters
        .map(
          (parameter) =>
            escape(parameter.name) +
            (parameter.constraints.length ? `:${parameter.constraints.map((c) => typeHtml(c, index)).join(' &amp; ')}` : ''),
        )
        .join(', ')}&gt;`;

const argumentsHtml = (args, index) =>
  args
    .map(
      (argument) =>
        `${argument.optional && argument.defaultValue == null ? '?' : ''}${escape(argument.name ?? '_')}:${typeHtml(argument.type, index)}` +
        (argument.defaultValue != null ? ` = ${escape(argument.defaultValue)}` : ''),
    )
    .join(', ');

/** A type's declaration line: its kind, name, type parameters and what it extends, implements or stands for. */
export function declarationHtml(type, index) {
  const name = escape(shortName(type.path)) + parametersHtml(type.typeParameters, index);
  const list = (word, types) => (types.length ? ` ${word} ${types.map((t) => typeHtml(t, index)).join(', ')}` : '');
  switch (type.kind) {
    case 'typedef':
      return `typedef ${name} = ${type.underlying ? typeHtml(type.underlying, index) : ''}`;
    case 'abstract':
      return (
        `${type.isExtern ? 'extern ' : ''}abstract ${name}(${type.underlying ? typeHtml(type.underlying, index) : ''})` +
        list('from', type.from) +
        list('to', type.to)
      );
    case 'interface':
      return `interface ${name}${list('extends', type.supertypes)}`;
    case 'enum':
      return `enum ${name}${list('implements', type.interfaces)}`;
    default:
      return `${type.kind === 'extern' ? 'extern class' : 'class'} ${name}${list('extends', type.supertypes)}${list('implements', type.interfaces)}`;
  }
}

/** A member's signature, as Haxe declares it. */
export function memberHtml(member, index) {
  const statically = member.isStatic && !['enumConstructor', 'enumValue', 'function'].includes(member.kind) ? 'static ' : '';
  switch (member.kind) {
    case 'field':
      return `${statically}${member.isFinal ? 'final' : 'var'} ${escape(member.name)}:${typeHtml(member.type, index)}`;
    case 'property':
      return `${statically}var ${escape(member.name)}(${member.get}, ${member.set}):${typeHtml(member.type, index)}`;
    case 'enumValue':
      return escape(member.name);
    case 'enumConstructor':
      return member.arguments.length ? `${escape(member.name)}(${argumentsHtml(member.arguments, index)})` : escape(member.name);
    case 'constructor':
      return `new(${argumentsHtml(member.arguments, index)})`;
    case 'operator':
      return `@:op(${escape(member.operatorText)}) (${argumentsHtml(member.arguments, index)}):${typeHtml(member.result, index)}`;
    case 'conversion':
      return `@:${member.conversion} (${argumentsHtml(member.arguments, index)}):${typeHtml(member.result, index)}`;
    default:
      return (
        `${statically}function ${escape(member.name)}${parametersHtml(member.typeParameters, index)}` +
        `(${argumentsHtml(member.arguments, index)}):${typeHtml(member.result, index)}`
      );
  }
}

/** Where a declaration's source is in the repository, when its package is one the build described. */
export function sourceUrl(packageName, position, index) {
  const directory = packageName ? index.directories.get(packageName) : null;
  return directory ? `${repositorySource(`packages/${directory}/${position.file}`)}#L${position.line}` : null;
}

export const memberAnchor = (type, member) => `${typeAnchor(type.path)}-${member.name}`;
export { shortName };
