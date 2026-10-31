#pragma once

#include "nativekit_gpu.h"
#include "prepare/atlas_texture_id.h"

#include <algorithm>
#include <array>
#include <cstring>
#include <unordered_map>
#include <vector>

namespace nkui {

struct GeometryKey {
    uint64_t generation = 0;
    uint32_t kind = 0;
    int width = 0, height = 0;
    std::array<uint32_t, 11> placement{};
    bool operator==(const GeometryKey &) const = default;
};
struct GeometryKeyHash {
    std::size_t operator()(const GeometryKey &key) const {
        uint64_t hash = key.generation;
        const auto mix = [&](uint32_t value) { hash = (hash ^ value) * UINT64_C(1099511628211); };
        mix(key.kind); mix(key.width); mix(key.height);
        for (const auto value : key.placement) mix(value);
        return hash;
    }
};

struct GeometryMesh {
    nkgpu_pipeline pipeline{};
    nkgpu_sampler sampler{};
    nkgpu_image image{};
    AtlasTextureKey atlas{};
    uint32_t stride = 0;
    std::vector<uint8_t> vertices, vertex_uniforms, fragment_uniforms;
    std::vector<uint32_t> indices;
};

/** Bounded immutable geometry versions; frame visits govern eviction, not scene invalidation. */
class RetainedGeometry {
  public:
    struct Range { std::size_t page = 0; uint32_t offset = 0, size = 0; };
    struct Mesh {
        nkgpu_pipeline pipeline{};
        nkgpu_sampler sampler{};
        nkgpu_image image{};
        AtlasTextureKey atlas{};
        uint32_t stride = 0, count = 0;
        Range vertices, indices;
        std::vector<uint8_t> vertex_uniforms, fragment_uniforms;
    };
    struct Entry {
        std::vector<Mesh> meshes;
        std::vector<uint8_t> commands;
        std::vector<uint32_t> images;
        uint64_t used = 0, first_frame = 0;
    };
    struct Page {
        nkgpu_buffer buffer{};
        nkgpu_buffer_usage usage = NKGPU_BUFFER_VERTEX;
        std::vector<uint8_t> bytes;
        std::vector<Range> free;
        bool dirty = true;
    };
    explicit RetainedGeometry(uint64_t budget) : budget_(budget) {}

    ~RetainedGeometry() {
        for (const auto &page : pages_) if (page.buffer.id) nkgpu_buffer_destroy(owner_, page.buffer);
    }
    void limit(uint64_t budget) { budget_ = std::min(budget_, budget); }
    void begin(uint64_t frame) { frame_ = frame; full_ = false; hits = misses = 0; }
    Entry *find(const GeometryKey &key) {
        const auto found = entries_.find(key);
        if (found == entries_.end()) {
            while (entries_.size() >= 4096) if (!evict()) return nullptr;
            auto &candidate = entries_[key];
            candidate.used = candidate.first_frame = frame_;
            return nullptr;
        }
        found->second.used = frame_;
        if (found->second.meshes.empty()) return nullptr;
        ++hits;
        return &found->second;
    }
    bool admit(const GeometryKey &key) {
        const auto found = entries_.find(key);
        const bool repeated = found != entries_.end() && found->second.first_frame != frame_;
        if (!repeated) ++misses;
        return repeated;
    }
    Entry *insert(const GeometryKey &key, const std::vector<GeometryMesh> &source) {
        ++misses;
        if (full_ || source.empty()) return nullptr;
        while (entries_.size() >= 4096 && !entries_.contains(key))
            if (!evict()) { full_ = true; return nullptr; }
        for (const auto &mesh : source)
            if (mesh.vertices.size() > page_bytes || mesh.indices.size() * sizeof(uint32_t) > page_bytes)
                return nullptr;
        Entry entry;
        entry.used = frame_;
        for (const auto &source_mesh : source) {
            Mesh mesh;
            mesh.pipeline = source_mesh.pipeline; mesh.sampler = source_mesh.sampler; mesh.image = source_mesh.image;
            mesh.atlas = source_mesh.atlas; mesh.stride = source_mesh.stride;
            mesh.count = static_cast<uint32_t>(source_mesh.indices.size());
            if (!allocate(NKGPU_BUFFER_VERTEX, source_mesh.vertices.data(), source_mesh.vertices.size(), mesh.vertices)) {
                release(entry); return nullptr;
            }
            if (!allocate(NKGPU_BUFFER_INDEX, reinterpret_cast<const uint8_t *>(source_mesh.indices.data()),
                          source_mesh.indices.size() * sizeof(uint32_t), mesh.indices)) {
                release(mesh.vertices); release(entry); return nullptr;
            }
            mesh.vertex_uniforms = source_mesh.vertex_uniforms;
            mesh.fragment_uniforms = source_mesh.fragment_uniforms;
            entry.meshes.push_back(std::move(mesh));
        }
        return &entries_.insert_or_assign(key, std::move(entry)).first->second;
    }
    bool upload(nkgpu_renderer renderer) {
        owner_ = renderer;
        last_result = NKGPU_OK;
        for (auto &page : pages_) {
            if (!page.dirty) continue;
            if (!page.buffer.id) {
                nkgpu_buffer_desc desc{};
                desc.struct_size = sizeof(desc); desc.size = page.bytes.size();
                desc.usage = page.usage; desc.dynamic_update = 1;
                desc.data = page.bytes.data(); desc.data_size = page.bytes.size();
                if ((last_result = nkgpu_buffer_create_desc(renderer, &desc, &page.buffer)) != NKGPU_OK) return false;
            } else if ((last_result = nkgpu_buffer_update(renderer, page.buffer, 0, page.bytes.data(), page.bytes.size())) != NKGPU_OK)
                return false;
            // Coalesce dirty ranges into one whole-page update. The adapter's
            // partial-update path copies its full shadow and can replace an object on a second update.
            page.dirty = false;
        }
        return true;
    }
    nkgpu_buffer buffer(const Range &range) const { return pages_[range.page].buffer; }
    const uint8_t *bytes(const Range &range) const { return pages_[range.page].bytes.data() + range.offset; }
    uint64_t size_bytes() const { return pages_.size() * uint64_t{page_bytes}; }
    bool matches(const Entry &entry, const std::vector<GeometryMesh> &source) const {
        if (entry.meshes.size() != source.size()) return false;
        for (std::size_t index = 0; index < source.size(); ++index) {
            const auto &a = entry.meshes[index]; const auto &b = source[index];
            if (a.pipeline.id != b.pipeline.id || a.sampler.id != b.sampler.id ||
                (!a.atlas.texture.value && a.image.id != b.image.id) ||
                a.atlas.texture.value != b.atlas.texture.value || a.atlas.generation != b.atlas.generation ||
                a.stride != b.stride || a.count != b.indices.size() || a.vertices.size != b.vertices.size() ||
                a.indices.size != b.indices.size() * sizeof(uint32_t) ||
                a.vertex_uniforms != b.vertex_uniforms || a.fragment_uniforms != b.fragment_uniforms ||
                std::memcmp(bytes(a.vertices), b.vertices.data(), a.vertices.size) ||
                std::memcmp(bytes(a.indices), b.indices.data(), a.indices.size)) return false;
        }
        return true;
    }
    uint64_t hits = 0, misses = 0;
    nkgpu_result last_result = NKGPU_OK;

  private:
    static constexpr uint32_t page_bytes = 64 * 1024;
    uint64_t budget_, frame_ = 0;
    nkgpu_renderer owner_{};
    bool full_ = false;
    std::vector<Page> pages_;
    std::unordered_map<GeometryKey, Entry, GeometryKeyHash> entries_;

    bool allocate(nkgpu_buffer_usage usage, const uint8_t *data, std::size_t size, Range &range) {
        if (!size) return false;
        const auto aligned = static_cast<uint32_t>((size + 3) & ~std::size_t{3});
        for (;;) {
            for (std::size_t index = 0; index < pages_.size(); ++index) {
                auto &page = pages_[index];
                if (page.usage != usage) continue;
                for (auto free = page.free.begin(); free != page.free.end(); ++free) {
                    if (free->size < aligned) continue;
                    range = {index, free->offset, static_cast<uint32_t>(size)};
                    std::memcpy(page.bytes.data() + free->offset, data, size);
                    free->offset += aligned; free->size -= aligned;
                    if (!free->size) page.free.erase(free);
                    page.dirty = true;
                    return true;
                }
            }
            if (size_bytes() + page_bytes <= budget_) {
                Page page; page.usage = usage; page.bytes.resize(page_bytes);
                page.free.push_back({pages_.size(), 0, page_bytes});
                pages_.push_back(std::move(page));
                continue;
            }
            if (!evict()) { full_ = true; return false; }
        }
    }
    bool evict() {
        auto oldest = entries_.end();
        for (auto entry = entries_.begin(); entry != entries_.end(); ++entry)
            if (entry->second.used != frame_ && (oldest == entries_.end() || entry->second.used < oldest->second.used))
                oldest = entry;
        if (oldest == entries_.end()) return false;
        release(oldest->second); entries_.erase(oldest); return true;
    }
    void release(Range range) {
        auto &free = pages_[range.page].free;
        range.size = (range.size + 3) & ~uint32_t{3};
        const auto position = std::lower_bound(free.begin(), free.end(), range.offset,
            [](const auto &range, uint32_t offset) { return range.offset < offset; });
        auto inserted = free.insert(position, range);
        if (inserted != free.begin()) {
            auto previous = inserted - 1;
            if (previous->offset + previous->size == inserted->offset) {
                previous->size += inserted->size; inserted = free.erase(inserted) - 1;
            }
        }
        if (inserted + 1 != free.end() && inserted->offset + inserted->size == (inserted + 1)->offset) {
            inserted->size += (inserted + 1)->size; free.erase(inserted + 1);
        }
    }
    void release(const Entry &entry) { for (const auto &mesh : entry.meshes) { release(mesh.vertices); release(mesh.indices); } }
};

} // namespace nkui
