// SPDX-License-Identifier: GPL-2.0-only
// Minimal test-tool platform services; never linked into the native application.
#include "tgf.h"
#include <filesystem>
#include <string>
static std::string dataDirectory;
static std::string localDirectory;
char *GetDataDir() { return dataDirectory.data(); }
char *GetLocalDir() { return localDirectory.data(); }
void SetDataDir(char *path) { dataDirectory = path ? path : ""; }
void SetLocalDir(char *path) { localDirectory = path ? path : ""; }
int GfCreateDir(char *path) {
    if (!path) return GF_DIR_CREATION_FAILED;
    std::error_code error;
    std::filesystem::create_directories(path, error);
    return error ? GF_DIR_CREATION_FAILED : GF_DIR_CREATED;
}
int GfCreateDirForFile(const char *path) {
    if (!path) return GF_DIR_CREATION_FAILED;
    auto parent = std::filesystem::path(path).parent_path().string();
    return parent.empty() ? GF_DIR_CREATED : GfCreateDir(parent.data());
}
