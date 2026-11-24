#!/usr/bin/env python3
"""Generate Haxe shader programs from NativeKit shader reflection."""

import argparse
import json
import re
from pathlib import Path

TARGETS = {
    "glsl410": "Glsl410", "glsl300es": "Glsl300Es", "hlsl5": "Hlsl5",
    "metal_macos": "MetalMacos", "metal_ios": "MetalIos",
}
TYPES = {
    "float": "Float", "vec2": "Float2", "vec3": "Float3", "vec4": "Float4",
    "int": "Int", "ivec2": "Int2", "ivec3": "Int3", "ivec4": "Int4", "mat4": "Mat4",
}
IMAGE_TYPES = {"2d": "TwoD", "array": "Array", "cube": "Cube", "cube_array": "CubeArray"}

FORMATS = {"float": ("Float", 4), "float2": ("Float2", 8), "float3": ("Float3", 12), "float4": ("Float4", 16)}


def words(name):
    if not re.fullmatch(r"[A-Za-z][A-Za-z0-9_]*", name):
        raise ValueError(f"invalid shader identifier {name}")
    return [part for part in name.split("_") if part]


def pascal(name):
    return "".join(part[0].upper() + part[1:] for part in words(name))


def camel(name):
    title = pascal(name)
    return title[0].lower() + title[1:]


def uniform_record(block, record):
    declarations, offsets = [], []
    cursor = 0
    for member in block["members"]:
        field, kind = camel(member["name"]), member["type"]
        scalar = "Int" if kind.startswith("i") else "Float32"
        components = 16 if kind == "mat4" else int(kind[-1]) if kind[-1].isdigit() else 1
        stride = member.get("array_stride", components * 4)
        for element in range(member["array_count"]):
            offset = member["offset"] + element * stride
            if offset < cursor or (offset - cursor) % 4:
                raise ValueError(f"{record}: invalid offset for {field}")
            for gap in range(cursor, offset, 4):
                declarations.append(f"\tprivate var pad{gap}:Int;")
            element_name = field if element == 0 else f"{field}_{element}"
            offsets.extend((json.dumps(element_name), str(offset)))
            for component in range(components):
                name = element_name if component == 0 else f"{element_name}_c{component}"
                declarations.append(f"\tpublic var {name}:{scalar};")
            cursor = offset + components * 4
    size = block["size"]
    if size < cursor or (size - cursor) % 4:
        raise ValueError(f"{record}: invalid std140 size {size}")
    for gap in range(cursor, size, 4):
        declarations.append(f"\tprivate var pad{gap}:Int;")
    return ["@:value", '@:repr("C")', f"@:assertLayout({', '.join([str(size), *offsets])})",
            f"class {record} {{", *declarations, "}", ""]


def vertex_layout(attributes):
    offset = 0
    fields, rows = [], []
    for attr in sorted(attributes, key=lambda attr: attr["slot"]):
        name = camel(attr["name"])
        format_type, size = FORMATS[attr["format"]]
        fields.append(f"\t\t{name}Offset: {offset},")
        rows.append(f"\t\t\t{{slot: {attr['slot']}, bufferIndex: 0, offset: {offset}, format: VertexFormat.{format_type}}},")
        offset += size
    return ["\tpublic static final Vertex = {", f"\t\tstride: {offset},", *fields,
            f"\t\tlayout: new VertexLayout({offset}, [", *rows, "\t\t])", "\t};", ""] if rows else []


def emit_program(lines, data, program, field, targets, private):
    attributes = next(iter(targets.values()))["attributes"]
    visibility = "private" if private else "public"
    lines.append(f"\t{visibility} static final {field} = new ShaderProgram([")
    for attr in attributes:
        semantic = attr["semantic"]
        lines.append(f"\t\t{{slot: {attr['slot']}, name: {json.dumps(attr['name'])}, "
                     f"semantic: {json.dumps(semantic['name'])}, semanticIndex: {semantic['index']}}},")
    lines.append("\t], [")
    for slang, description in targets.items():
        if description["storage_buffers"]:
            raise ValueError(f"{program}: storage buffers are unsupported in shader tables")
        lines.extend(("\t\t{", f"\t\t\ttarget: ShaderTarget.{TARGETS[slang]},"))
        for stage in ("vertex", "fragment"):
            entry = description["stages"][stage]
            expected = "main0" if slang.startswith("metal_") else "main"
            if entry["entry_point"] != expected:
                raise ValueError(f"{program}: unsupported {stage} entry for {slang}")
            lines.append(f"\t\t\t{stage}: {json.dumps(data['sources'][entry['source']])},")
        blocks = [
            f"{{slot: {block['slot']}, stage: ShaderStage.{block['stage'].capitalize()}, size: {block['size']}}}"
            for block in description["uniform_blocks"]
        ]
        uniforms = [
            f"{{block: {block['slot']}, member: {index}, name: {json.dumps(member['name'])}, "
            f"type: UniformType.{TYPES[member['type']]}, count: {member['array_count']}}}"
            for block in description["uniform_blocks"]
            for index, member in enumerate(block["gl_uniforms"])
        ]
        textures = []
        images = {image["slot"]: image for image in description["images"]}
        for pair in description["image_sampler_pairs"]:
            image = images[pair["image_slot"]]
            if image["sample_type"] != "float" or image["multisampled"]:
                raise ValueError(f"{program}: unsupported texture sample type")
            textures.append(f"{{view: {image['slot']}, sampler: {pair['sampler_slot']}, "
                            f"stage: ShaderStage.{image['stage'].capitalize()}, "
                            f"type: ImageType.{IMAGE_TYPES[image['type']]}, name: {json.dumps(pair['name'])}}}")
        for label, rows, suffix in (("blocks", blocks, ","), ("uniforms", uniforms, ","), ("textures", textures, "")):
            if rows:
                lines.append(f"\t\t\t{label}: [")
                lines.extend(f"\t\t\t\t{row}," for row in rows)
                lines.append(f"\t\t\t]{suffix}")
            else:
                lines.append(f"\t\t\t{label}: []{suffix}")
        lines.append("\t\t},")
    lines.extend(("\t]);", ""))


def generate(data, names, name, package, selected_variant):
    if data.get("schema") != "nkgpu-shader-reflection/1":
        raise ValueError("unsupported shader reflection schema")
    selected = {program: data["programs"][program] for program in names}
    blocks, attributes = {}, None
    for variants in selected.values():
        for variant, entry in variants.items():
            if selected_variant is not None and variant != selected_variant:
                continue
            target = next(iter(entry["targets"].values()))
            if attributes is None:
                attributes = target["attributes"]
            if attributes != target["attributes"]:
                raise ValueError("programs in a module require one vertex interface")
            for block in target["uniform_blocks"]:
                interface = {key: block[key] for key in ("slot", "stage", "size", "members", "name")}
                if block["name"] in blocks and blocks[block["name"]] != interface:
                    raise ValueError(f"conflicting layouts for block {block['name']}")
                blocks[block["name"]] = interface
    if attributes is None:
        raise ValueError("no programs selected")
    lines = ["// Generated by packages/gpu/tools/generate-shader-haxe.py. Do not edit."]
    if package:
        lines.extend((f"package {package};", ""))
    lines.extend(("import haxeon.gpu.Enums;", "import haxeon.gpu.Renderer;", "import haxeon.gpu.Shader;",
                  "import haxeon.gpu.ShaderProgram;", "import haxeon.gpu.VertexLayout;"))
    if blocks:
        lines.append("import haxeon.gpu.ShaderUniformBlock;")
    lines.append("")
    members, enums = vertex_layout(attributes), []
    for block in blocks.values():
        record = name + pascal(block["name"])
        lines.extend(uniform_record(block, record))
        declaration = (f"\tpublic static final {camel(block['name'])} = new ShaderUniformBlock<{record}>("
                       f"{block['slot']}, ShaderStage.{block['stage'].capitalize()},")
        size = f"sizeof<{record}>());"
        if len(declaration) + len(size) > 109:
            members.extend((declaration, f"\t\t{size}"))
        else:
            members.append(f"{declaration} {size}")
    if blocks:
        members.append("")
    declarations = []
    for program, variants in selected.items():
        field = camel(program)
        if selected_variant is not None or len(variants) == 1:
            variant = selected_variant if selected_variant is not None else next(iter(variants))
            emit_program(members, data, program, field, variants[variant]["targets"], False)
            declarations.append((field, None))
            continue
        enum_type = name + pascal(program) + "Variant"
        cases = {pascal(variant): variant for variant in variants}
        if len(cases) != len(variants):
            raise ValueError(f"{program}: duplicate variant name")
        enums.extend((f"enum {enum_type} {{", *(f"\t{label};" for label in cases), "}", ""))
        for label, variant in cases.items():
            emit_program(members, data, program, field + label, variants[variant]["targets"], True)
        members.extend((f"\tpublic static function {field}(variant:{enum_type}):ShaderProgram {{",
                        "\t\treturn switch variant {",
                        *(f"\t\t\tcase {label}: {field}{label};" for label in cases),
                        "\t\t}", "\t}", ""))
        declarations.append((field, enum_type))
    if len(declarations) == 1:
        field, enum_type = declarations[0]
        argument = f", variant:{enum_type}" if enum_type else ""
        program_expr = f"{field}(variant)" if enum_type else field
        members.extend((f"\tpublic static function create(renderer:Renderer{argument}):Shader",
                        f"\t\treturn Shader.create(renderer, {program_expr});"))
    elif members[-1] == "":
        members.pop()
    lines.extend((*enums, f"class {name} {{", *members, "}", ""))
    return "\n".join(lines).encode()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("reflection", type=Path)
    parser.add_argument("program")
    parser.add_argument("output", type=Path)
    parser.add_argument("--variant")
    parser.add_argument("--package")
    parser.add_argument("--check", action="store_true")
    args = parser.parse_args()
    try:
        data = json.loads(args.reflection.read_text(encoding="utf-8"))
        names = args.program.split(",")
        output = generate(data, names, args.output.stem, args.package, args.variant)
        if args.check:
            if args.output.read_bytes() != output:
                raise ValueError(f"{args.output} is stale")
        else:
            args.output.write_bytes(output)
    except (KeyError, OSError, ValueError) as error:
        parser.exit(1, f"{error}\n")


if __name__ == "__main__":
    main()
