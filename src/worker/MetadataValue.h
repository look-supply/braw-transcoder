#pragma once
#include "BlackmagicRawAPI.h"
#include <cstring>
#include <iomanip>
#include <sstream>
#include <string>

namespace CameraMetadata {
inline std::string String(CFStringRef value) {
    if (!value) return {};
    const auto size = CFStringGetMaximumSizeForEncoding(CFStringGetLength(value), kCFStringEncodingUTF8) + 1;
    std::string result(size, '\0');
    if (!CFStringGetCString(value, result.data(), size, kCFStringEncodingUTF8)) return {};
    result.resize(std::strlen(result.c_str()));
    return result;
}

template<typename T> inline std::string Array(const void* data, uint32_t count) {
    const auto* values = static_cast<const T*>(data);
    std::ostringstream text;
    text << std::setprecision(17) << '[';
    for (uint32_t i = 0; i < count; ++i) {
        if (i) text << ", ";
        // U8 is a number, rather than a character.
        text << +values[i];
    }
    text << ']';
    return text.str();
}

inline std::string Value(const Variant& value) {
    switch (value.vt) {
        case blackmagicRawVariantTypeEmpty: return {};
        case blackmagicRawVariantTypeString: return String(value.bstrVal);
        case blackmagicRawVariantTypeU8: return std::to_string(value.uiVal & 0xff);
        case blackmagicRawVariantTypeU16: return std::to_string(value.uiVal);
        case blackmagicRawVariantTypeU32: return std::to_string(value.uintVal);
        case blackmagicRawVariantTypeS16: return std::to_string(value.iVal);
        case blackmagicRawVariantTypeS32: return std::to_string(value.intVal);
        case blackmagicRawVariantTypeFloat32: return std::to_string(value.fltVal);
        case blackmagicRawVariantTypeFloat64: return std::to_string(value.dblVal);
        case blackmagicRawVariantTypeSafeArray: {
            auto* array = value.parray;
            if (!array) return "[]";
            // The SDK's SafeArray ABI has a single bound; do not interpret an
            // unfamiliar multidimensional payload using that single bound.
            if (array->cDims != 1) return "[Array with " + std::to_string(array->cDims) + " dimensions]";
            void* data = nullptr;
            if (FAILED(SafeArrayAccessData(array, &data))) return "[Array unavailable]";
            const auto count = array->bounds.cElements;
            std::string result;
            if (!count) result = "[]";
            else if (!data) result = "[Array unavailable]";
            else switch (array->variantType) {
                case blackmagicRawVariantTypeU8: result = Array<uint8_t>(data, count); break;
                case blackmagicRawVariantTypeS16: result = Array<int16_t>(data, count); break;
                case blackmagicRawVariantTypeU16: result = Array<uint16_t>(data, count); break;
                case blackmagicRawVariantTypeS32: result = Array<int32_t>(data, count); break;
                case blackmagicRawVariantTypeU32: result = Array<uint32_t>(data, count); break;
                case blackmagicRawVariantTypeFloat32: result = Array<float>(data, count); break;
                case blackmagicRawVariantTypeFloat64: result = Array<double>(data, count); break;
                case blackmagicRawVariantTypeString: {
                    const auto* strings = static_cast<const CFStringRef*>(data);
                    result = "[";
                    for (uint32_t i = 0; i < count; ++i) {
                        if (i) result += ", ";
                        std::ostringstream quoted;
                        quoted << std::quoted(String(strings[i]));
                        result += quoted.str();
                    }
                    result += "]";
                    break;
                }
                default: result = "[Array of " + std::to_string(count) + " values, type " + std::to_string(array->variantType) + "]";
            }
            SafeArrayUnaccessData(array);
            return result;
        }
        default: return "[Metadata type " + std::to_string(value.vt) + "]";
    }
}
}
