#include "core/QuickTimeMetadata.h"
#include <filesystem>
#include <fstream>
#include <iostream>
#include <stdexcept>
#include <string>
#include <unistd.h>

static void require(bool value, const char* error) {
    if (!value) throw std::runtime_error(error);
}
static std::string box(const char* type, const std::string& payload) {
    uint32_t size = payload.size()+8;
    std::string result;
    for (int shift : {24,16,8,0}) result += char(size >> shift);
    return result + std::string(type,4) + payload;
}
static std::string load(const std::string& path) {
    std::ifstream file(path,std::ios::binary);
    return {std::istreambuf_iterator<char>(file), std::istreambuf_iterator<char>()};
}
int main() {
    char path[] = "/private/tmp/braw-qt-metadata-XXXXXX";
    int fd = mkstemp(path);
    if (fd < 0) return 1;
    close(fd);
    try {
        const auto metadata = box("meta",std::string(4,'\0') + box("keys","camera identifiers"));
        const auto other = box("name","other metadata must survive");
        const auto chunkOffsets = box("trak",box("stco","chunk offsets must survive"));
        const auto media = box("mdat","encoded video and audio bytes must survive");
        auto check = [&](const std::string& before, const std::string& expected) {
            {std::ofstream file(path,std::ios::binary); file.write(before.data(),before.size());}
            std::string error;
            require(PromoteQuickTimeMetadata(path,error),error.c_str());
            require(load(path)==expected,"Metadata relocation changed media, offsets, or other atoms");
            require(PromoteQuickTimeMetadata(path,error),"Already-finalized file rejected");
            require(load(path)==expected,"Repeated finalization changed file");
        };
        // Both faststart and moov-at-end layouts keep all chunk offsets exact.
        const auto originalMoov = box("moov",chunkOffsets+box("udta",other+metadata));
        const auto finalMoov = box("moov",chunkOffsets+box("udta",other)+metadata);
        check(originalMoov+media,finalMoov+media);
        check(media+originalMoov,media+finalMoov);
        check(box("moov",box("udta",metadata))+media,
              box("moov",box("udta","")+metadata)+media);
        for (const auto& malformed : {box("moov",box("udta",box("name","no metadata"))),
             box("moov",box("udta",metadata+metadata)),box("moov","broken")}) {
            {std::ofstream file(path,std::ios::binary);file.write(malformed.data(),malformed.size());}
            std::string error;
            require(!PromoteQuickTimeMetadata(path,error),"Malformed metadata accepted");
            require(!error.empty(),"Missing error detail");
            require(load(path)==malformed,"Failed finalization changed file");
        }
        std::filesystem::remove(path);
        std::cout << "PASS: QuickTime metadata placement, offset preservation, idempotence, and failure safety\n";
        return 0;
    } catch (const std::exception& exception) {
        std::filesystem::remove(path);
        std::cerr << exception.what() << '\n'; return 1;
    }
}
