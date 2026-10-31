#include "frame_resources.h"

namespace nkui {

OwnedFrameResources::GraphicsImageLease::~GraphicsImageLease() {
    if (image.id)
        nk_graphics_image_release(image);
}

bool FrameResources::bind_path(ResourceId id, const PreparedPathData &path,
                               uint32_t operation_index, uint64_t content_generation) {
    if (!is_resource_id(id, ResourceKind::Path) || operation_index >= path.operations().size())
        return false;
    paths_.bind(id.value) = {&path, operation_index};
    content_generations_.bind(id.value) = content_generation;
    return true;
}

bool FrameResources::bind_path(ResourceId id, const PreparedPath &path, uint32_t operation_index,
                               uint64_t content_generation) {
    return bind_path(id, path.data(), operation_index, content_generation);
}

bool FrameResources::bind_image(ResourceId id, const PreparedTexture &image,
                                uint64_t content_generation) {
    if (!is_resource_id(id, ResourceKind::Image) || image.width <= 0 || image.height <= 0 ||
        image.pixels.empty())
        return false;
    images_.bind(id.value) = {&image};
    content_generations_.bind(id.value) = content_generation;
    return true;
}

bool FrameResources::bind_text(ResourceId id, const PreparedGlyphs &glyphs,
                               uint64_t content_generation, ResourceId source_identity) {
    if (!is_resource_id(id, ResourceKind::TextLayout))
        return false;
    if (source_identity.value &&
        (!is_resource_id(source_identity, ResourceKind::TextLayout) ||
         (source_identity.value != id.value && !content_generation)))
        return false;
    source_identities_.bind(id.value) = source_identity.value ? source_identity : id;
    texts_.bind(id.value) = &glyphs;
    content_generations_.bind(id.value) = content_generation;
    return true;
}

bool FrameResources::bind_surface(ResourceId id, SurfaceProducer &producer,
                                  uint64_t content_generation) {
    if (!is_resource_id(id, ResourceKind::RenderTarget))
        return false;
    surfaces_.bind(id.value) = &producer;
    content_generations_.bind(id.value) = content_generation;
    return true;
}

bool FrameResources::bind_graphics_image(ResourceId id, nk_graphics_image image,
                                         uint64_t content_generation) {
    if (!is_resource_id(id, ResourceKind::RenderTarget) || !image.id)
        return false;
    graphics_images_.bind(id.value) = image;
    content_generations_.bind(id.value) = content_generation;
    return true;
}

const PreparedPathRef *FrameResources::path(ResourceId id) const { return paths_.get(id.value); }
const PreparedImageRef *FrameResources::image(ResourceId id) const { return images_.get(id.value); }
const PreparedGlyphs *FrameResources::text(ResourceId id) const {
    const auto *value = texts_.get(id.value); return value ? *value : nullptr;
}
SurfaceProducer *FrameResources::surface(ResourceId id) const {
    const auto *value = surfaces_.get(id.value); return value ? *value : nullptr;
}
const nk_graphics_image *FrameResources::graphics_image(ResourceId id) const { return graphics_images_.get(id.value); }
uint64_t FrameResources::content_generation(ResourceId id) const {
    const auto *value = content_generations_.get(id.value); return value ? *value : 0;
}
ResourceId FrameResources::source_identity(ResourceId id) const {
    const auto *value = source_identities_.get(id.value); return value ? *value : id;
}

void FrameResources::reset() {
    paths_.reset();
    images_.reset();
    texts_.reset();
    surfaces_.reset();
    graphics_images_.reset();
    content_generations_.reset();
    source_identities_.reset();
}

bool OwnedFrameResources::bind_path(ResourceId id, std::shared_ptr<const PreparedPath> path,
                                    uint32_t operation_index, uint64_t content_generation) {
    if (!path || !FrameResources::bind_path(id, path->data(), operation_index, content_generation))
        return false;
    owners_.push_back(std::move(path));
    return true;
}

bool OwnedFrameResources::bind_image(ResourceId id, std::shared_ptr<const PreparedTexture> image,
                                     uint64_t content_generation) {
    if (!image || !FrameResources::bind_image(id, *image, content_generation))
        return false;
    owners_.push_back(std::move(image));
    return true;
}

bool OwnedFrameResources::bind_text(ResourceId id, std::shared_ptr<const PreparedGlyphs> glyphs,
                                    uint64_t content_generation, ResourceId source_identity) {
    if (!glyphs || !FrameResources::bind_text(id, *glyphs, content_generation, source_identity))
        return false;
    owners_.push_back(std::move(glyphs));
    return true;
}

bool OwnedFrameResources::bind_graphics_image(ResourceId id, nk_graphics_image image,
                                              uint64_t content_generation) {
    if (!image.id || nk_graphics_image_retain(image) != NK_OK)
        return false;
    if (!FrameResources::bind_graphics_image(id, image, content_generation)) {
        nk_graphics_image_release(image);
        return false;
    }
    auto lease = std::make_shared<GraphicsImageLease>();
    lease->image = image;
    graphics_image_leases_[id.value] = std::move(lease);
    return true;
}

void OwnedFrameResources::reset() {
    graphics_image_leases_.clear();
    owners_.clear();
    FrameResources::reset();
}

} // namespace nkui
