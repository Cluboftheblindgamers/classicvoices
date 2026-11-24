#pragma once

#include <stdio.h>
#include <string.h>

// Packaged engine images may have a resource header. They are guest data,
// separate from the native executables that a sideloading tool signs.
static inline FILE *cv_open_engine_resource(const char *path, long *offset) {
    static const char header[] = "CVENGINE";
    char prefix[sizeof header - 1];
    FILE *file = fopen(path, "rb");
    if (!file) return NULL;
    *offset = fread(prefix, 1, sizeof prefix, file) == sizeof prefix &&
              memcmp(prefix, header, sizeof prefix) == 0 ? (long)sizeof prefix : 0;
    if (fseek(file, *offset, SEEK_SET) != 0) {
        fclose(file);
        return NULL;
    }
    return file;
}
