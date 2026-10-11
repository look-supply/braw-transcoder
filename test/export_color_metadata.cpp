#include "core/ExportColorMetadata.h"
#include "core/ExportRecordingMetadata.h"
#include <iostream>
#include <map>
#include <stdexcept>

static void require(bool value, const char* message) {
    if (!value) throw std::runtime_error(message);
}

int main() {
    try {
        const std::string camera = "Blackmagic Pocket Cinema Camera 6K Pro";
        auto tags = BlackmagicFilmMetadata("Blackmagic Design Film", "Blackmagic Design", 5, camera);
        std::map<std::string,std::string> metadata(tags.begin(), tags.end());
        require(metadata.at("com.apple.proapps.customgamma") == "com.blackmagic-design.camera.filmlog", "Missing camera Film identifier");
        require(metadata.at("com.blackmagic-design.camera.cameraType") == camera, "Camera identity changed");
        require(metadata.at("com.blackmagic-design.camera.colorScience") == "Blackmagic URSA Mini Pro 12K, Color Science Gen 5", "Missing recognized common Gen5 profile");
        auto fullFrame = BlackmagicFilmMetadata("Blackmagic Design Film", "Blackmagic Design", 5, "Blackmagic Cinema Camera 6K");
        std::map<std::string,std::string> fullFrameMetadata(fullFrame.begin(),fullFrame.end());
        require(fullFrameMetadata.at("com.blackmagic-design.camera.cameraType") == "Blackmagic Cinema Camera 6K", "Full-frame camera identity changed");
        require(fullFrameMetadata.at("com.blackmagic-design.camera.colorScience") == metadata.at("com.blackmagic-design.camera.colorScience"), "Common Gen5 profile depends on camera spelling");
        auto gen6 = BlackmagicFilmMetadata("DaVinci Intermediate", "DaVinci Wide Gamut", 6, "Blackmagic URSA Cine 12K LF");
        std::map<std::string,std::string> gen6Metadata(gen6.begin(),gen6.end());
        require(gen6Metadata.at("com.blackmagic-design.camera.colorScience") == "Blackmagic URSA Cine 12K LF, Color Science Gen 6", "Gen6 labeled as Gen5");
        require(BlackmagicFilmMetadata("Blackmagic Design Film", "DaVinci Wide Gamut", 5, camera).empty(), "Gen5 DWG output incorrectly labeled camera Film");
        require(BlackmagicFilmMetadata("DaVinci Intermediate", "DaVinci Wide Gamut", 5, camera).empty(), "Gen5 intermediate incorrectly labeled native camera Film");
        require(BlackmagicFilmMetadata("Blackmagic Design Film", "Blackmagic Design", 6, camera).empty(), "Gen6 incorrectly labeled with Gen5 encoding");
        require(BlackmagicFilmMetadata("Blackmagic Design Custom", "Blackmagic Design", 4, camera).empty(), "Custom gamma incorrectly labeled Film");
        require(BlackmagicFilmMetadata("Blackmagic Design Film", "Rec.709", 5, camera).empty(), "Other gamut incorrectly labeled camera Film");
        require(BlackmagicFilmMetadata("Blackmagic Design Film", "Blackmagic Design", 5, "").empty(), "Missing camera identity accepted");
        require(BlackmagicFilmMetadata("Blackmagic Design Film", "Blackmagic Design", 5, "Panasonic S1H").empty(), "External camera incorrectly labeled Blackmagic Film");
        require(BlackmagicFilmMetadata("Blackmagic Design Film", "Blackmagic Design", 0, camera).empty(), "Unknown generation accepted");
        require(BlackmagicFilmMetadata("Blackmagic Design Film", "Blackmagic Design", 7, camera).empty(), "Future generation guessed");
        ClipAdjustments adjustments;
        adjustments.iso=800; adjustments.colorTemp=5600; adjustments.tint=-3;
        adjustments.exposure=1; adjustments.highlightRecovery=true;
        const auto recording=RecordingMetadata({
            {"lens_type","LUMIX S 20-60/F3.5-5.6"}, {"focal_length","27mm"},
            {"white_balance_kelvin","4500"}, {"white_balance_tint","15"},
            {"iso","400"}, {"date_recorded","2026:07:18"},
            {"shutter_type","Angle"}, {"shutter_value","180°"}, {"good_take","false"}
        },adjustments,24);
        require(recording.at("com.blackmagic-design.camera.lensType")=="LUMIX S 20-60/F3.5-5.6", "Lens lost");
        require(recording.at("com.blackmagic-design.camera.lensFocalLength")=="27mm", "Lens units lost");
        require(recording.at("com.blackmagic-design.camera.whiteBalanceKelvin")=="5600", "WB does not match render");
        require(recording.at("com.blackmagic-design.camera.whiteBalanceTint")=="-3", "Signed tint lost");
        require(recording.at("com.blackmagic-design.camera.iso")=="800", "ISO does not match render");
        require(recording.at("com.brawtranscoder.source.metadata.white_balance_kelvin")=="4500", "Original WB lost");
        require(recording.at("com.blackmagic-design.camera.dateRecorded")=="2026-07-18", "Recording date malformed");
        require(recording.at("com.blackmagic-design.shutterAngle")=="180°", "Shutter angle lost");
        require(!recording.contains("com.blackmagic-design.camera.lensDistance"), "Missing focus distance fabricated");
        require(!recording.contains("com.apple.proapps.isGood"), "Untyped good-take flag would display ASCII code");
        std::cout << "PASS: source-driven Film metadata and unsupported-encoding guards\n";
        return 0;
    } catch (const std::exception& error) {
        std::cerr << "FAIL: " << error.what() << '\n';
        return 1;
    }
}
