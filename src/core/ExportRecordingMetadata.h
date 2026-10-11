#pragma once
#include "core/Types.h"
#include <map>
#include <string>

// Resolve's camera/ProApps QuickTime keys. Unmapped source scalar fields are
// retained separately; the MOV's camera metadata is a first-frame snapshot.
inline std::map<std::string, std::string> RecordingMetadata(
    const std::map<std::string, std::string>& source,
    const ClipAdjustments& adjustments, float projectFPS) {
    std::map<std::string, std::string> result;
    for (const auto& [key, value] : source)
        if (!value.empty()) result["com.brawtranscoder.source.metadata." + key] = value;
    const std::pair<const char*, const char*> mappings[] = {
        {"manufacturer", "com.apple.proapps.manufacturer"},
        {"camera_type", "com.blackmagic-design.camera.cameraType"},
        {"camera_id", "com.blackmagic-design.camera.uuid"},
        {"firmware_version", "com.blackmagic-design.camera.firmware"},
        {"clip_number", "com.apple.proapps.clipID"},
        {"camera_number", "com.apple.proapps.cameraName"},
        {"reel_name", "com.apple.proapps.reel"},
        {"scene", "com.apple.proapps.scene"},
        {"take", "com.apple.proapps.shot"},
        {"production_name", "com.blackmagic-design.camera.projectName"},
        {"director", "com.blackmagic-design.camera.director"},
        {"camera_operator", "com.blackmagic-design.camera.cameraOp"},
        {"day_night", "com.blackmagic-design.camera.dayNight"},
        {"environment", "com.blackmagic-design.camera.environment"},
        {"take_type", "com.apple.proapps.angle"},
        {"frameguide_aspect_ratio", "com.blackmagic-design.camera.guides.aspectRatio"},
        {"lens_filter", "com.blackmagic-design.camera.lensFilter"},
        {"timelapse_interval", "com.blackmagic-design.camera.timelapseInterval"},
        {"shot_type", "com.blackmagic-design.camera.shotType"},
        {"lens_type", "com.blackmagic-design.camera.lensType"},
        {"aperture", "com.blackmagic-design.camera.aperture"},
        {"focal_length", "com.blackmagic-design.camera.lensFocalLength"},
        {"distance", "com.blackmagic-design.camera.lensDistance"},
        {"internal_nd", "com.blackmagic-design.camera.NDFilter"},
        {"sensor_fps", "com.blackmagic-design.sensorFPS"},
        {"offspeed", "com.blackmagic-design.camera.offspeed"},
        {"shutter_type", "com.blackmagic-design.shutterMode"},
    };
    for (const auto& [from, to] : mappings) {
        auto found = source.find(from);
        if (found != source.end() && !found->second.empty()) result[to] = found->second;
    }
    auto get = [&](const char* key) {
        auto found = source.find(key);
        return found == source.end() ? std::string{} : found->second;
    };
    if (!get("shutter_value").empty()) {
        const auto suffix = get("shutter_type") == "Angle" ? "shutterAngle" : "shutterSpeed";
        result[std::string("com.blackmagic-design.") + suffix] = get("shutter_value");
        result[std::string("com.blackmagic-design.camera.") + suffix] = get("shutter_value");
    }
    auto date = get("date_recorded");
    if (date.size() == 10 && date[4] == ':' && date[7] == ':') {
        date[4] = date[7] = '-';
        result["com.blackmagic-design.camera.dateRecorded"] = date;
    }
    // Resolve reads isGood as a binary byte, interpreting a UTF-8 "0" as
    // decimal 48. Keep this flag in source.metadata until typed mdta is supported.
    // These describe the rendered image; original camera settings remain in
    // source.metadata even when the user changes the export's WB or ISO.
    if (adjustments.iso > 0) result["com.blackmagic-design.camera.iso"] = std::to_string(adjustments.iso);
    if (adjustments.colorTemp > 0) result["com.blackmagic-design.camera.whiteBalanceKelvin"] = std::to_string(adjustments.colorTemp);
    result["com.blackmagic-design.camera.whiteBalanceTint"] = std::to_string(adjustments.tint);
    result["com.blackmagic-design.camera.projectFPS"] = std::to_string(projectFPS);
    result["com.brawtranscoder.export.exposure"] = std::to_string(adjustments.exposure);
    result["com.brawtranscoder.export.highlight_recovery"] = adjustments.highlightRecovery ? "1" : "0";
    return result;
}
