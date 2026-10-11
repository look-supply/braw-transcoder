#pragma once
#include <cstdint>
#include <string>
#include <utility>
#include <vector>

// These are the camera's QuickTime metadata keys, not invented NCLC codes.
// Resolve recognizes the Gen4/5 camera Film encoding using these keys at
// moov/meta. Gen6 values are preserved, but Resolve 21.1 did not automatically
// detect the DWG/Intermediate fixture, even with generation-qualified keys.
inline std::vector<std::pair<std::string, std::string>> BlackmagicFilmMetadata(
    const std::string& gamma, const std::string& gamut,
    uint16_t generation, const std::string& camera) {
    const bool legacyFilm = generation >= 4 && generation <= 5 &&
        gamma == "Blackmagic Design Film" && gamut == "Blackmagic Design";
    // SDK 6 selects this pair when Gen6 is selected. The camera Film-log
    // identifier is qualified by colorScience's generation, not a Gen5 curve.
    const bool gen6Film = generation == 6 &&
        gamma == "DaVinci Intermediate" && gamut == "DaVinci Wide Gamut";
    if ((!legacyFilm && !gen6Film) || !camera.starts_with("Blackmagic "))
        return {};
    // Resolve's QuickTime reader recognizes selected historical camera names
    // in colorScience, but ignores "Blackmagic Cinema Camera 6K" there. Gen5
    // has a common published gamut/OETF; use its recognized reference profile
    // while cameraType and source.camera_type preserve the actual camera.
    const std::string colorScience = generation == 5
        ? "Blackmagic URSA Mini Pro 12K, Color Science Gen 5"
        : camera + ", Color Science Gen " + std::to_string(generation);
    return {
        {"com.apple.proapps.manufacturer", "Blackmagic Design"},
        {"com.blackmagic-design.camera.cameraType", camera},
        {"com.blackmagic-design.camera.colorScience", colorScience},
        {"com.apple.proapps.customgamma", "com.blackmagic-design.camera.filmlog"}
    };
}
