#include "worker/MetadataValue.h"
#include "core/BrawDecoder.h"
#include "BlackmagicRawAPIDispatch.cpp"
#include <cstdlib>
#include <iostream>

#define require(condition) do { if (!(condition)) { std::cerr << "Failed at line " << __LINE__ << ": " << #condition << "\n"; std::abort(); } } while (false)
int main(int argc, char** argv) {
    auto* factory = CreateBlackmagicRawFactoryInstanceFromPath(CFSTR(BRAW_SDK_LIBRARY_PATH));
    require(factory != nullptr);
    Variant value; VariantInit(&value);
    require(CameraMetadata::Value(value).empty());
    value.vt = blackmagicRawVariantTypeString;
    value.bstrVal = CFSTR("a camera ✓");
    require(CameraMetadata::Value(value) == "a camera ✓");
    value.vt = blackmagicRawVariantTypeS16; value.iVal = -12;
    require(CameraMetadata::Value(value) == "-12");
    value.vt = blackmagicRawVariantTypeU32; value.uintVal = UINT32_MAX;
    require(CameraMetadata::Value(value) == "4294967295");
    SafeArrayBound bounds{0, 3};
    auto* array = SafeArrayCreate(blackmagicRawVariantTypeU8, 1, &bounds);
    require(array != nullptr);
    void* data = nullptr; require(SafeArrayAccessData(array, &data) == S_OK);
    auto* bytes = static_cast<uint8_t*>(data);
    bytes[0] = 0; bytes[1] = 127; bytes[2] = 255;
    SafeArrayUnaccessData(array);
    value.vt = blackmagicRawVariantTypeSafeArray; value.parray = array;
    require(CameraMetadata::Value(value) == "[0, 127, 255]");
    VariantClear(&value);
    value.vt = 999;
    require(CameraMetadata::Value(value) == "[Metadata type 999]");
    factory->Release();
    if (argc == 2) {
        BrawDecoder decoder;
        require(decoder.OpenClip(argv[1]));
        const auto all = decoder.GetInspectorMetadata();
        const auto exported = decoder.GetFreeFormMetadata();
        require(!all.empty());
        for (const auto& [key, text] : exported) {
            require(all.contains(key) && all.at(key) == text);
        }
        require(!all.contains("crop_origin"));
        require(!all.contains("post_3dlut_embedded_data"));
        require(!all.contains("post_3dlut_sidecar_data"));
        require(all.contains("post_3dlut_embedded_name"));
        std::cout << "Full inspector metadata and scalar export metadata remain separate\n";
    }
    std::cout << "Camera metadata preserves empty, Unicode, signed, unsigned, array and unknown values\n";
}
