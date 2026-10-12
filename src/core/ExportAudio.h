#pragma once
#include <cstdint>
#include <string>
#include <vector>

// SDK audio is interleaved PCM in source channel order. Camera inputs are
// discrete channels, so do not infer a surround layout or remix/re-encode them.
inline std::vector<std::string> ExportAudioArguments(uint32_t rate, uint32_t channels,
                                                    uint32_t bits, const std::string& pcmPath) {
    return {"-f", "s" + std::to_string(bits) + "le", "-ar", std::to_string(rate),
            "-ac", std::to_string(channels), "-guess_layout_max", "0", "-i", pcmPath,
            "-map", "0:v:0", "-map", "1:a:0", "-c:a", "copy"};
}
