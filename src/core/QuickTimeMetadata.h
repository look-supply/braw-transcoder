#pragma once
#include <string>

// Resolve reads camera mdta from moov/meta, whereas FFmpeg writes it under
// moov/udta/meta. Move only metadata, preserving every media/chunk offset.
bool PromoteQuickTimeMetadata(const std::string& path, std::string& error);
