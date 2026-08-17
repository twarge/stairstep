#pragma once

#include <stdbool.h>
#include <stdint.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct HNStepVertex {
    float x;
    float y;
    float z;
    float nx;
    float ny;
    float nz;
    float r;
    float g;
    float b;
    // Index of the originating OpenCascade face, so callers can distinguish real
    // face boundaries/edges from interior tessellation edges. All vertices of a
    // given tessellated face share one id.
    uint32_t faceId;
} HNStepVertex;

typedef struct HNStepMesh {
    HNStepVertex *vertices;
    uint32_t vertexCount;
    uint32_t *indices;
    uint32_t indexCount;
} HNStepMesh;

typedef enum HNModelFormat {
    HNModelFormatSTEP = 0,
    HNModelFormatIGES = 1,
    HNModelFormatBREP = 2,
    HNModelFormatSTL = 3,
    HNModelFormatPLY = 4,
    HNModelFormatOBJ = 5,
    HNModelFormatGLB = 6
} HNModelFormat;

// Reports progress as a fraction in [0, 1]. May be invoked from worker threads
// during parallel tessellation, so the callback must be thread-safe. Pass NULL
// (with a NULL context) to disable progress reporting.
typedef void (*HNProgressCallback)(void *context, double fraction);

// Imports a STEP model directly from an in-memory buffer, avoiding a temporary
// file round trip. progress/context are optional.
bool HNModelImportData(const void *data, size_t length, HNStepMesh *mesh,
                       HNProgressCallback progress, void *context);

// Imports a model file of the given format by path. progress/context are optional.
bool HNModelImport(const char *path, int32_t format, HNStepMesh *mesh,
                   HNProgressCallback progress, void *context);

// One drawn occurrence of an in-memory OpenCascade BREP payload. Several
// instances may share one payload (a FreeCAD link array draws the same shape
// many times); the importer parses each unique payload once, keyed by pointer.
typedef struct HNBRepInstance {
    // ASCII "CASCADE Topology" BREP payload.
    const void *bytes;
    size_t length;
    // Optional rigid transform applied on top of the payload's own location:
    // a unit quaternion (x, y, z, w) followed by a translation, FreeCAD's
    // placement convention. hasPlacement false draws the payload as stored.
    bool hasPlacement;
    double quaternion[4];
    double position[3];
    // Optional colours, 3 floats (r, g, b in 0...1) each. BREP carries no colour
    // of its own, so for FreeCAD documents this is where display colours — read
    // from GuiDocument.xml — enter the mesh. colorCount 0 falls back to the
    // importer default; 1 colours the whole shape; N colours faces one by one in
    // TopExp::MapShapes(TopAbs_FACE) order (FreeCAD's DiffuseColor order), any
    // extra faces keeping the last colour.
    const float *colors;
    size_t colorCount;
} HNBRepInstance;

// Imports BREP instances as one model, tessellating unique payloads together in
// a single parallel pass. Used for container formats that store one BREP per
// object (FreeCAD .FCStd), where the caller has already unpacked the container
// and chosen which shapes to draw where. Instances whose payload fails to parse
// are skipped; the call succeeds if any shape yielded geometry. progress/context
// are optional.
bool HNModelImportBReps(const HNBRepInstance *instances, size_t count,
                        HNStepMesh *mesh, HNProgressCallback progress, void *context);

void HNStepMeshFree(HNStepMesh *mesh);

#ifdef __cplusplus
}
#endif
