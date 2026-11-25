#pragma once

#include <array>
#include <atomic>
#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <initializer_list>
#include <cstdint>

namespace nkui {

inline bool render_cost_enabled() {
    static const bool enabled = [] {
        const char *value = std::getenv("HAXEON_UI_RENDER_COST");
        return value && value[0] == '1' && value[1] == '\0';
    }();
    return enabled;
}

inline bool render_verification_enabled() {
    static const bool enabled = [] {
        const auto enabled = [](const char *name) {
            const char *value = std::getenv(name);
            return value && std::strtol(value, nullptr, 10) > 0;
        };
        return enabled("HAXEON_UI_VERIFY_RETENTION") || enabled("HAXEON_UI_VERIFY_RENDER");
    }();
    return enabled;
}

inline double render_cost_time() {
    return render_cost_enabled()
        ? std::chrono::duration<double>(std::chrono::steady_clock::now().time_since_epoch()).count()
        : 0.0;
}

inline uint64_t &render_cost_frame() {
    static thread_local uint64_t frame = 0;
    return frame;
}

/** Correlates an inline execution or a render-worker ticket without changing submission payloads. */
class RenderCostFrame {
  public:
    explicit RenderCostFrame(uint64_t frame = 0) : enabled_(render_cost_enabled()) {
        if (!enabled_)
            return;
        static std::atomic<uint64_t> sequence{0};
        previous_ = render_cost_frame();
        render_cost_frame() = frame ? frame : sequence.fetch_add(1, std::memory_order_relaxed) + 1;
    }
    ~RenderCostFrame() {
        if (enabled_)
            render_cost_frame() = previous_;
    }
    void set(uint64_t frame) {
        if (enabled_)
            render_cost_frame() = frame;
    }

  private:
    bool enabled_;
    uint64_t previous_ = 0;
};

/** Stack-only opt-in phase accumulator. Disabled probes do not read clocks or format output. */
class RenderCostProbe {
  public:
    RenderCostProbe(const char *stage, std::initializer_list<const char *> phases)
        : enabled_(render_cost_enabled()), stage_(stage) {
        if (!enabled_)
            return;
        for (const auto phase : phases)
            if (count_ < names_.size()) names_[count_++] = phase;
        wall_started_ = std::chrono::duration<double>(
            std::chrono::system_clock::now().time_since_epoch()).count();
        started_ = last_ = render_cost_time();
    }

    void mark(std::size_t phase) {
        if (!enabled_)
            return;
        const auto now = render_cost_time();
        values_[phase] += now - last_;
        last_ = now;
    }

    void add(std::size_t phase, double seconds) {
        if (enabled_) values_[phase] += seconds;
    }

    ~RenderCostProbe() {
        if (!enabled_)
            return;
        const auto total = render_cost_time() - started_;
        double measured = 0.0;
        for (std::size_t index = 0; index < count_; ++index) measured += values_[index];
        char line[2048];
        auto used = std::snprintf(line, sizeof(line),
            "render-cost %s id=%llu started=%.9f nodes=%zu primitives=%zu passes=%zu commands=%zu reused=%d success=%d segments_compiled=%zu segments_reused=%zu meshes_compiled=%zu meshes_reused=%zu mesh_cache_bytes=%zu total=%.9f other=%.9f",
            stage_, static_cast<unsigned long long>(render_cost_frame()), wall_started_,
            nodes, primitives, passes, commands, reused, success, segments_compiled, segments_reused, meshes_compiled, meshes_reused, mesh_cache_bytes, total, total - measured);
        for (std::size_t index = 0; index < count_ && used >= 0 &&
                static_cast<std::size_t>(used) < sizeof(line); ++index) {
            const auto wrote = std::snprintf(line + used, sizeof(line) - used,
                " %s=%.9f", names_[index], values_[index]);
            if (wrote < 0) return;
            used += wrote;
        }
        if (used >= 0 && static_cast<std::size_t>(used) < sizeof(line))
            std::fprintf(stderr, "%s\n", line);
    }

    bool enabled() const { return enabled_; }
    std::size_t nodes = 0, primitives = 0, passes = 0, commands = 0;
    bool reused = false, success = false;
    std::size_t segments_compiled = 0, segments_reused = 0;
    std::size_t meshes_compiled = 0, meshes_reused = 0, mesh_cache_bytes = 0;

  private:
    bool enabled_;
    const char *stage_;
    std::array<const char *, 10> names_{};
    std::array<double, 10> values_{};
    std::size_t count_ = 0;
    double wall_started_ = 0.0, started_ = 0.0, last_ = 0.0;
};

inline uint64_t &render_cost_draw_count() {
    static thread_local uint64_t count = 0;
    return count;
}

inline RenderCostProbe *&render_cost_mesh_probe() {
    static thread_local RenderCostProbe *probe = nullptr;
    return probe;
}

class RenderCostMeshScope {
  public:
    explicit RenderCostMeshScope(RenderCostProbe &probe) : previous_(render_cost_mesh_probe()) {
        if (probe.enabled()) render_cost_mesh_probe() = &probe;
    }
    ~RenderCostMeshScope() { render_cost_mesh_probe() = previous_; }
  private:
    RenderCostProbe *previous_;
};

} // namespace nkui
