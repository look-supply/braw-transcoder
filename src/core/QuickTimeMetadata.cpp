#include "QuickTimeMetadata.h"
#include <algorithm>
#include <array>
#include <cstring>
#include <filesystem>
#include <fstream>
#include <stdexcept>
#include <vector>

namespace {
using Bytes = std::vector<uint8_t>;
uint64_t readNumber(const uint8_t* p, size_t count) {
    uint64_t n = 0;
    for (size_t i = 0; i < count; ++i) n = (n << 8) | p[i];
    return n;
}
void writeNumber(uint8_t* p, uint64_t n, size_t count) {
    for (size_t i = count; i > 0; --i) { p[i-1] = uint8_t(n); n >>= 8; }
}
struct Box { size_t start, size, header; };
bool isType(const Bytes& bytes, const Box& box, const char* type) {
    return std::memcmp(bytes.data()+box.start+4, type, 4) == 0;
}
std::vector<Box> children(const Bytes& bytes, size_t start, size_t end) {
    std::vector<Box> result;
    while (start < end) {
        if (end-start < 8) throw std::runtime_error("Truncated MOV atom header");
        uint64_t size = readNumber(bytes.data()+start, 4);
        size_t header = 8;
        if (size == 1) {
            if (end-start < 16) throw std::runtime_error("Truncated extended MOV atom header");
            size = readNumber(bytes.data()+start+8, 8); header = 16;
        } else if (size == 0) size = end-start;
        if (size < header || size > end-start) throw std::runtime_error("Invalid MOV atom size");
        result.push_back({start, size_t(size), header});
        start += size;
    }
    return result;
}
void append(Bytes& out, const Bytes& source, size_t start, size_t size) {
    out.insert(out.end(), source.begin()+start, source.begin()+start+size);
}
Bytes promote(const Bytes& moov, size_t header) {
    const auto boxes = children(moov, header, moov.size());
    for (auto box : boxes) if (isType(moov, box, "meta")) return moov;
    Bytes result, metadata;
    append(result, moov, 0, header);
    for (auto box : boxes) {
        if (!isType(moov, box, "udta")) {
            append(result, moov, box.start, box.size); continue;
        }
        Bytes udta;
        append(udta, moov, box.start, box.header);
        for (auto child : children(moov, box.start+box.header, box.start+box.size)) {
            if (isType(moov, child, "meta")) {
                if (!metadata.empty()) throw std::runtime_error("Multiple MOV metadata atoms");
                append(metadata, moov, child.start, child.size);
            } else append(udta, moov, child.start, child.size);
        }
        // Retain even an empty udta header: the total moov length stays exact,
        // so faststart stco/co64 addresses and mdat bytes never need rewriting.
        if (box.header == 16) writeNumber(udta.data()+8, udta.size(), 8);
        else writeNumber(udta.data(), udta.size(), 4);
        result.insert(result.end(), udta.begin(), udta.end());
    }
    if (metadata.empty()) throw std::runtime_error("MOV metadata atom is missing");
    result.insert(result.end(), metadata.begin(), metadata.end());
    if (result.size() != moov.size()) throw std::runtime_error("MOV metadata relocation changed chunk offsets");
    return result;
}
}

bool PromoteQuickTimeMetadata(const std::string& path, std::string& error) {
    try {
        const uint64_t length = std::filesystem::file_size(path);
        std::fstream file(path, std::ios::in | std::ios::out | std::ios::binary);
        if (!file) throw std::runtime_error("Cannot open export for MOV metadata finalization");
        uint64_t start = 0;
        while (start < length) {
            if (length-start < 8) throw std::runtime_error("Truncated MOV file");
            std::array<uint8_t,16> head{};
            file.seekg(start); file.read(reinterpret_cast<char*>(head.data()),8);
            uint64_t size = readNumber(head.data(),4);
            size_t header = 8;
            if (size == 1) {
                if (length-start < 16) throw std::runtime_error("Truncated extended MOV file atom");
                file.read(reinterpret_cast<char*>(head.data()+8),8);
                size = readNumber(head.data()+8,8); header = 16;
            } else if (size == 0) size = length-start;
            if (!file || size < header || size > length-start) throw std::runtime_error("Invalid MOV file atom");
            if (std::memcmp(head.data()+4,"moov",4) == 0) {
                if (size > 64*1024*1024) throw std::runtime_error("MOV index exceeds metadata finalization memory limit");
                Bytes original(size);
                file.seekg(start); file.read(reinterpret_cast<char*>(original.data()),original.size());
                if (!file) throw std::runtime_error("Cannot read MOV index");
                auto updated = promote(original,header);
                if (updated != original) {
                    file.seekp(start); file.write(reinterpret_cast<const char*>(updated.data()),updated.size());
                    file.flush();
                    if (!file) throw std::runtime_error("Cannot write MOV metadata");
                }
                error.clear(); return true;
            }
            start += size;
        }
        throw std::runtime_error("MOV index is missing");
    } catch (const std::exception& exception) {
        error = exception.what(); return false;
    }
}
