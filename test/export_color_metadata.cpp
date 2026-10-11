#include "core/ExportColorMetadata.h"
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
        std::cout << "PASS: source-driven Film metadata and unsupported-encoding guards\n";
        return 0;
    } catch (const std::exception& error) {
        std::cerr << "FAIL: " << error.what() << '\n';
        return 1;
    }
}
