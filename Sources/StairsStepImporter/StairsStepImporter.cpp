#include "StairsStepImporter.h"

#include <BRep_Builder.hxx>
#include <BRepMesh_IncrementalMesh.hxx>
#include <BRep_Tool.hxx>
#include <BRepTools.hxx>
#include <DEBREP_Provider.hxx>
#include <DEGLTF_Provider.hxx>
#include <DEIGES_Provider.hxx>
#include <DEOBJ_Provider.hxx>
#include <DEPLY_Provider.hxx>
#include <DESTL_Provider.hxx>
#include <IFSelect_ReturnStatus.hxx>
#include <IMeshTools_Parameters.hxx>
#include <Interface_Static.hxx>
#include <Message_ProgressIndicator.hxx>
#include <Message_ProgressRange.hxx>
#include <Message_ProgressScope.hxx>
#include <NCollection_Sequence.hxx>
#include <Poly.hxx>
#include <Poly_Triangulation.hxx>
#include <Precision.hxx>
#include <Quantity_Color.hxx>
#include <STEPCAFControl_Reader.hxx>
#include <Standard_Failure.hxx>
#include <Standard_Handle.hxx>
#include <Standard_Version.hxx>
#include <TDF_Label.hxx>
#include <TDocStd_Document.hxx>
#include <NCollection_IndexedMap.hxx>
#include <TopExp.hxx>
#include <TopLoc_Location.hxx>
#include <TopAbs_Orientation.hxx>
#include <TopTools_ShapeMapHasher.hxx>
#include <TopoDS.hxx>
#include <TopoDS_Compound.hxx>
#include <TopoDS_Face.hxx>
#include <TopoDS_Shape.hxx>
#include <TopoDS_Iterator.hxx>
#include <gp_Quaternion.hxx>
#include <gp_Trsf.hxx>
#include <TCollection_AsciiString.hxx>
#include <XCAFApp_Application.hxx>
#include <XCAFDoc_ColorTool.hxx>
#include <XCAFDoc_DocumentTool.hxx>
#include <XCAFDoc_ShapeTool.hxx>

#include <algorithm>
#include <cstdlib>
#include <cstring>
#include <fstream>
#include <exception>
#include <functional>
#include <map>
#include <sstream>
#include <string>
#include <utility>
#include <vector>

namespace {

constexpr double userPrecision = 0.14;
constexpr double userAngle = 0.52359878;

struct MeshAccumulator {
    std::vector<HNStepVertex> vertices;
    std::vector<uint32_t> indices;
    occ::handle<XCAFDoc_ColorTool> colorTool;
    occ::handle<XCAFDoc_ShapeTool> shapeTool;
    uint32_t nextFaceId = 0;
};

// Bridges OCCT's progress reporting to the C callback. Show() may be invoked
// from meshing worker threads, so the callback must be thread-safe.
class CallbackProgress : public Message_ProgressIndicator {
public:
    CallbackProgress(HNProgressCallback callback, void *context)
        : myCallback(callback), myContext(context) {}

    void Show(const Message_ProgressScope &, const Standard_Boolean) override
    {
        if (myCallback != nullptr) {
            myCallback(myContext, GetPosition());
        }
    }

    Standard_Boolean UserBreak() override { return Standard_False; }

private:
    HNProgressCallback myCallback;
    void *myContext;
};

bool transferSTEP(
    STEPCAFControl_Reader &reader,
    occ::handle<TDocStd_Document> &document,
    const Message_ProgressRange &range
) {
    if (!Interface_Static::SetIVal("read.precision.mode", 1)) {
        return false;
    }
    if (!Interface_Static::SetRVal("read.precision.val", userPrecision)) {
        return false;
    }

    reader.SetColorMode(true);
    reader.SetNameMode(false);
    reader.SetLayerMode(false);

    if (!reader.Transfer(document, range)) {
        document->Close();
        return false;
    }

    return reader.NbRootsForTransfer() >= 1;
}

bool readSTEP(const char *path, occ::handle<TDocStd_Document> &document, const Message_ProgressRange &range)
{
    STEPCAFControl_Reader reader;
    if (reader.ReadFile(path) != IFSelect_RetDone) {
        return false;
    }
    return transferSTEP(reader, document, range);
}

// Reads STEP straight from an in-memory buffer, skipping any temporary file.
bool readSTEPStream(
    const void *data,
    size_t length,
    occ::handle<TDocStd_Document> &document,
    const Message_ProgressRange &range
) {
    STEPCAFControl_Reader reader;
    std::istringstream stream(std::string(static_cast<const char *>(data), length));
    if (reader.ReadStream("model.step", stream) != IFSelect_RetDone) {
        return false;
    }
    return transferSTEP(reader, document, range);
}

template <typename Provider>
bool readWithProvider(const char *path, occ::handle<TDocStd_Document> &document, const Message_ProgressRange &range)
{
    try {
        Provider provider;
        return provider.Read(TCollection_AsciiString(path), document, range);
    } catch (const Standard_Failure &) {
        return false;
    } catch (const std::exception &) {
        return false;
    } catch (...) {
        return false;
    }
}

bool hasAsciiBRepHeader(const char *path)
{
    std::ifstream stream(path, std::ios::in | std::ios::binary);
    if (!stream) {
        return false;
    }

    std::string line;
    for (int lineIndex = 0; lineIndex < 4 && std::getline(stream, line); lineIndex++) {
        if (line.find("CASCADE Topology") != std::string::npos) {
            return true;
        }
    }
    return false;
}

bool readAsciiBRep(const char *path, occ::handle<TDocStd_Document> &document, const Message_ProgressRange &range)
{
    try {
        BRep_Builder builder;
        TopoDS_Shape shape;
        if (!BRepTools::Read(shape, path, builder, range) || shape.IsNull()) {
            return false;
        }

        occ::handle<XCAFDoc_ShapeTool> shapeTool = XCAFDoc_DocumentTool::ShapeTool(document->Main());
        if (shapeTool.IsNull()) {
            return false;
        }

        shapeTool->AddShape(shape, true);
        return true;
    } catch (const Standard_Failure &) {
        return false;
    } catch (const std::exception &) {
        return false;
    } catch (...) {
        return false;
    }
}

bool readBREP(const char *path, occ::handle<TDocStd_Document> &document, const Message_ProgressRange &range)
{
    if (hasAsciiBRepHeader(path) && readAsciiBRep(path, document, range)) {
        return true;
    }

    return readWithProvider<DEBREP_Provider>(path, document, range);
}

// Defined below; the BREP-instance path reuses the same face emitter as the
// XCAF-document path.
void appendFace(
    MeshAccumulator &accumulator,
    const TopoDS_Face &face,
    const Quantity_Color *inheritedColor,
    const gp_Trsf &parentTransform
);

// Parses each unique BREP payload once (instances of a link array share their
// payload pointer) and places one copy per instance. A payload that fails to
// parse is skipped so a single bad object doesn't lose the whole document.
std::vector<TopoDS_Shape> readBRepInstances(
    const HNBRepInstance *instances,
    size_t count,
    const Message_ProgressRange &range
) {
    Message_ProgressScope scope(range, nullptr, static_cast<double>(count == 0 ? 1 : count));
    std::map<std::pair<const void *, size_t>, TopoDS_Shape> parsed;
    std::vector<TopoDS_Shape> shapes(count);

    for (size_t index = 0; index < count; index++) {
        Message_ProgressRange step = scope.Next();
        const HNBRepInstance &instance = instances[index];
        if (instance.bytes == nullptr || instance.length == 0) {
            continue;
        }

        const auto key = std::make_pair(instance.bytes, instance.length);
        TopoDS_Shape shape;
        const auto found = parsed.find(key);
        if (found != parsed.end()) {
            shape = found->second;
        } else {
            try {
                BRep_Builder builder;
                std::istringstream stream(
                    std::string(static_cast<const char *>(instance.bytes), instance.length));
                // The stream overload returns void — a failed parse shows up as
                // a null shape.
                BRepTools::Read(shape, stream, builder, step);
            } catch (const Standard_Failure &) {
                shape.Nullify();
            } catch (const std::exception &) {
                shape.Nullify();
            } catch (...) {
                shape.Nullify();
            }
            // Failures are cached too, so a broken payload is parsed only once.
            parsed.emplace(key, shape);
        }
        if (shape.IsNull()) {
            continue;
        }

        if (instance.hasPlacement) {
            gp_Trsf transform;
            transform.SetRotation(gp_Quaternion(
                instance.quaternion[0],
                instance.quaternion[1],
                instance.quaternion[2],
                instance.quaternion[3]
            ));
            transform.SetTranslationPart(gp_Vec(
                instance.position[0],
                instance.position[1],
                instance.position[2]
            ));
            // Moved() composes the placement *outside* the stored location.
            shape = shape.Moved(TopLoc_Location(transform));
        }
        shapes[index] = shape;
    }

    return shapes;
}

// Emits one instance's faces with its colours. Faces are enumerated in
// TopExp::MapShapes order — the order FreeCAD's own view provider assigns
// DiffuseColor entries by — so a per-face colour list lines up exactly.
void appendInstanceFaces(
    MeshAccumulator &accumulator,
    const TopoDS_Shape &shape,
    const float *colors,
    size_t colorCount
) {
    NCollection_IndexedMap<TopoDS_Shape, TopTools_ShapeMapHasher> faceMap;
    TopExp::MapShapes(shape, TopAbs_FACE, faceMap);

    const gp_Trsf identity;
    Quantity_Color color;
    for (int index = 1; index <= faceMap.Extent(); index++) {
        const TopoDS_Face &face = TopoDS::Face(faceMap.FindKey(index));
        const Quantity_Color *faceColor = nullptr;
        if (colors != nullptr && colorCount > 0) {
            const size_t colorIndex =
                std::min(colorCount - 1, static_cast<size_t>(index - 1));
            const float *rgb = colors + colorIndex * 3;
            color.SetValues(rgb[0], rgb[1], rgb[2], Quantity_TOC_RGB);
            faceColor = &color;
        }
        // The face's location already carries the instance placement (the map
        // was built from the moved shape), so no parent transform remains.
        appendFace(accumulator, face, faceColor, identity);
    }
}

// The whole BREP-instance import: parse, tessellate every unique payload in one
// parallel pass (instances share TShapes, so an array meshes its payload once),
// then emit per instance. No XCAF document — BREP carries no metadata worth
// routing through one.
bool importBRepInstances(
    const HNBRepInstance *instances,
    size_t count,
    HNStepMesh *mesh,
    HNProgressCallback progress,
    void *context
) {
    HNStepMeshFree(mesh);

    occ::handle<CallbackProgress> indicator;
    Message_ProgressRange rootRange;
    if (progress != nullptr) {
        indicator = new CallbackProgress(progress, context);
        rootRange = indicator->Start();
    }
    Message_ProgressScope root(rootRange, nullptr, 10.0);

    std::vector<TopoDS_Shape> shapes = readBRepInstances(instances, count, root.Next(6.0));

    TopoDS_Compound compound;
    BRep_Builder compoundBuilder;
    compoundBuilder.MakeCompound(compound);
    bool hasShape = false;
    for (const TopoDS_Shape &shape : shapes) {
        if (!shape.IsNull()) {
            compoundBuilder.Add(compound, shape);
            hasShape = true;
        }
    }
    if (!hasShape) {
        return false;
    }

    IMeshTools_Parameters parameters;
    parameters.Deflection = userPrecision;
    parameters.Angle = userAngle;
    parameters.Relative = Standard_False;
    parameters.InParallel = Standard_True;
    // Constructing the mesher performs the (parallel) tessellation.
    BRepMesh_IncrementalMesh mesher(compound, parameters, root.Next(4.0));

    MeshAccumulator accumulator;
    for (size_t index = 0; index < count; index++) {
        if (shapes[index].IsNull()) {
            continue;
        }
        appendInstanceFaces(
            accumulator,
            shapes[index],
            instances[index].colors,
            instances[index].colorCount
        );
    }

    if (accumulator.vertices.empty() || accumulator.indices.empty()) {
        return false;
    }

    mesh->vertexCount = static_cast<uint32_t>(accumulator.vertices.size());
    mesh->indexCount = static_cast<uint32_t>(accumulator.indices.size());
    mesh->vertices = static_cast<HNStepVertex *>(std::malloc(sizeof(HNStepVertex) * mesh->vertexCount));
    mesh->indices = static_cast<uint32_t *>(std::malloc(sizeof(uint32_t) * mesh->indexCount));

    if (mesh->vertices == nullptr || mesh->indices == nullptr) {
        HNStepMeshFree(mesh);
        return false;
    }

    std::memcpy(mesh->vertices, accumulator.vertices.data(), sizeof(HNStepVertex) * mesh->vertexCount);
    std::memcpy(mesh->indices, accumulator.indices.data(), sizeof(uint32_t) * mesh->indexCount);
    return true;
}

bool readDocument(
    const char *path,
    HNModelFormat format,
    occ::handle<TDocStd_Document> &document,
    const Message_ProgressRange &range
) {
    switch (format) {
    case HNModelFormatSTEP:
        return readSTEP(path, document, range);
    case HNModelFormatIGES:
        return readWithProvider<DEIGES_Provider>(path, document, range);
    case HNModelFormatBREP:
        return readBREP(path, document, range);
    case HNModelFormatSTL:
        return readWithProvider<DESTL_Provider>(path, document, range);
    case HNModelFormatPLY:
        return readWithProvider<DEPLY_Provider>(path, document, range);
    case HNModelFormatOBJ:
        return readWithProvider<DEOBJ_Provider>(path, document, range);
    case HNModelFormatGLB:
        return readWithProvider<DEGLTF_Provider>(path, document, range);
    }

    return false;
}

bool getColor(MeshAccumulator &accumulator, TDF_Label label, Quantity_Color &color)
{
    if (accumulator.colorTool.IsNull()) {
        return false;
    }

    while (!label.IsNull()) {
        if (accumulator.colorTool->GetColor(label, XCAFDoc_ColorGen, color)
            || accumulator.colorTool->GetColor(label, XCAFDoc_ColorSurf, color)
            || accumulator.colorTool->GetColor(label, XCAFDoc_ColorCurv, color)) {
            return true;
        }

        label = label.Father();
    }

    return false;
}

Quantity_Color faceColor(
    MeshAccumulator &accumulator,
    const TopoDS_Face &face,
    const Quantity_Color *inheritedColor
) {
    Quantity_Color color;
    TDF_Label label;

    if (!accumulator.colorTool.IsNull()
        && accumulator.colorTool->ShapeTool()->Search(face, label)) {
        if (accumulator.colorTool->GetColor(label, XCAFDoc_ColorGen, color)
            || accumulator.colorTool->GetColor(label, XCAFDoc_ColorCurv, color)
            || accumulator.colorTool->GetColor(label, XCAFDoc_ColorSurf, color)) {
            return color;
        }
    }

    if (inheritedColor != nullptr) {
        return *inheritedColor;
    }

    return Quantity_Color(0.5, 0.5, 0.5, Quantity_TOC_RGB);
}

gp_Trsf combinedTransform(const gp_Trsf &parentTransform, const TopLoc_Location &location)
{
    gp_Trsf transform = parentTransform;
    transform.Multiply(location.Transformation());
    return transform;
}

bool shapeCarriesPlacementLocation(const TopoDS_Shape &shape)
{
    switch (shape.ShapeType()) {
    case TopAbs_COMPOUND:
    case TopAbs_COMPSOLID:
    case TopAbs_SOLID:
        return true;
    default:
        return false;
    }
}

void appendFace(
    MeshAccumulator &accumulator,
    const TopoDS_Face &face,
    const Quantity_Color *inheritedColor,
    const gp_Trsf &parentTransform
) {
    if (face.IsNull()) {
        return;
    }

    TopLoc_Location location;
    occ::handle<Poly_Triangulation> triangulation = BRep_Tool::Triangulation(face, location);

    if (triangulation.IsNull() || triangulation->Deflection() > userPrecision + Precision::Confusion()) {
        BRepMesh_IncrementalMesh mesh(face, userPrecision, false, userAngle);
        triangulation = BRep_Tool::Triangulation(face, location);
    }

    if (triangulation.IsNull() || triangulation->NbNodes() <= 0 || triangulation->NbTriangles() <= 0) {
        return;
    }

    const Quantity_Color color = faceColor(accumulator, face, inheritedColor);
    const gp_Trsf transform = combinedTransform(parentTransform, location);
    const uint32_t vertexBase = static_cast<uint32_t>(accumulator.vertices.size());
    accumulator.vertices.reserve(accumulator.vertices.size() + triangulation->NbNodes());

    const uint32_t faceId = accumulator.nextFaceId++;

    Poly::ComputeNormals(triangulation);
    for (int nodeIndex = 1; nodeIndex <= triangulation->NbNodes(); nodeIndex++) {
        gp_Pnt point = triangulation->Node(nodeIndex);
        point.Transform(transform);

        gp_Dir normal = triangulation->Normal(nodeIndex);
        normal.Transform(transform);

        accumulator.vertices.push_back(HNStepVertex {
            static_cast<float>(point.X()),
            static_cast<float>(point.Y()),
            static_cast<float>(point.Z()),
            static_cast<float>(normal.X()),
            static_cast<float>(normal.Y()),
            static_cast<float>(normal.Z()),
            static_cast<float>(color.Red()),
            static_cast<float>(color.Green()),
            static_cast<float>(color.Blue()),
            faceId
        });
    }

    accumulator.indices.reserve(accumulator.indices.size() + triangulation->NbTriangles() * 3);
    for (int triangleIndex = 1; triangleIndex <= triangulation->NbTriangles(); triangleIndex++) {
        int a = 0;
        int b = 0;
        int c = 0;
        triangulation->Triangle(triangleIndex).Get(a, b, c);

        if (face.Orientation() == TopAbs_REVERSED) {
            std::swap(b, c);
        }

        accumulator.indices.push_back(vertexBase + static_cast<uint32_t>(a - 1));
        accumulator.indices.push_back(vertexBase + static_cast<uint32_t>(b - 1));
        accumulator.indices.push_back(vertexBase + static_cast<uint32_t>(c - 1));
    }
}

void processShell(
    MeshAccumulator &accumulator,
    const TopoDS_Shape &shape,
    const Quantity_Color *inheritedColor,
    const gp_Trsf &transform
) {
    for (TopoDS_Iterator iterator(shape, false, false); iterator.More(); iterator.Next()) {
        const TopoDS_Shape &subShape = iterator.Value();
        if (subShape.ShapeType() == TopAbs_FACE) {
            appendFace(accumulator, TopoDS::Face(subShape), inheritedColor, transform);
        }
    }
}

void processShape(
    MeshAccumulator &accumulator,
    const TopoDS_Shape &shape,
    const gp_Trsf &parentTransform,
    const Quantity_Color *forcedColor = nullptr
)
{
    if (shape.IsNull()) {
        return;
    }

    const gp_Trsf transform = shapeCarriesPlacementLocation(shape)
        ? combinedTransform(parentTransform, shape.Location())
        : parentTransform;
    Quantity_Color color;
    const Quantity_Color *inheritedColor = forcedColor;

    if (inheritedColor == nullptr && !accumulator.shapeTool.IsNull()) {
        TDF_Label label = accumulator.shapeTool->FindShape(shape, false);
        if (!label.IsNull() && getColor(accumulator, label, color)) {
            inheritedColor = &color;
        }
    }

    switch (shape.ShapeType()) {
    case TopAbs_COMPOUND:
    case TopAbs_COMPSOLID:
    case TopAbs_SOLID:
        for (TopoDS_Iterator iterator(shape, false, false); iterator.More(); iterator.Next()) {
            processShape(accumulator, iterator.Value(), transform, inheritedColor);
        }
        break;
    case TopAbs_SHELL:
        processShell(accumulator, shape, inheritedColor, transform);
        break;
    case TopAbs_FACE:
        appendFace(accumulator, TopoDS::Face(shape), inheritedColor, transform);
        break;
    default:
        break;
    }
}

bool buildMeshFromDocument(
    occ::handle<TDocStd_Document> &document,
    HNStepMesh *mesh,
    const Message_ProgressRange &meshRange
) {
    MeshAccumulator accumulator;
    accumulator.shapeTool = XCAFDoc_DocumentTool::ShapeTool(document->Main());
    accumulator.colorTool = XCAFDoc_DocumentTool::ColorTool(document->Main());

    NCollection_Sequence<TDF_Label> freeShapes;
    accumulator.shapeTool->GetFreeShapes(freeShapes);

    // Tessellate every face of every root shape in a single parallel pass, rather
    // than meshing face-by-face on demand in appendFace(). On a multi-core machine
    // this is the biggest single win for large models.
    TopoDS_Compound compound;
    BRep_Builder compoundBuilder;
    compoundBuilder.MakeCompound(compound);
    bool hasShape = false;
    for (int shapeIndex = 1; shapeIndex <= freeShapes.Length(); shapeIndex++) {
        TopoDS_Shape shape = accumulator.shapeTool->GetShape(freeShapes.Value(shapeIndex));
        if (!shape.IsNull()) {
            compoundBuilder.Add(compound, shape);
            hasShape = true;
        }
    }

    if (hasShape) {
        IMeshTools_Parameters parameters;
        parameters.Deflection = userPrecision;
        parameters.Angle = userAngle;
        parameters.Relative = Standard_False;
        parameters.InParallel = Standard_True;
        // Constructing the mesher performs the (parallel) tessellation.
        BRepMesh_IncrementalMesh mesher(compound, parameters, meshRange);
    }

    gp_Trsf identity;
    for (int shapeIndex = 1; shapeIndex <= freeShapes.Length(); shapeIndex++) {
        TopoDS_Shape shape = accumulator.shapeTool->GetShape(freeShapes.Value(shapeIndex));
        processShape(accumulator, shape, identity);
    }

    document->Close();

    if (accumulator.vertices.empty() || accumulator.indices.empty()) {
        return false;
    }

    mesh->vertexCount = static_cast<uint32_t>(accumulator.vertices.size());
    mesh->indexCount = static_cast<uint32_t>(accumulator.indices.size());
    mesh->vertices = static_cast<HNStepVertex *>(std::malloc(sizeof(HNStepVertex) * mesh->vertexCount));
    mesh->indices = static_cast<uint32_t *>(std::malloc(sizeof(uint32_t) * mesh->indexCount));

    if (mesh->vertices == nullptr || mesh->indices == nullptr) {
        HNStepMeshFree(mesh);
        return false;
    }

    std::memcpy(mesh->vertices, accumulator.vertices.data(), sizeof(HNStepVertex) * mesh->vertexCount);
    std::memcpy(mesh->indices, accumulator.indices.data(), sizeof(uint32_t) * mesh->indexCount);
    return true;
}

// Splits progress into a read phase (~60%) and a tessellation phase (~40%),
// forwarding both to the optional callback. The read phase covers OCCT's STEP
// transfer / import; the mesh phase covers parallel tessellation.
bool importDocument(
    HNStepMesh *mesh,
    HNProgressCallback progress,
    void *context,
    const std::function<bool(occ::handle<TDocStd_Document> &, const Message_ProgressRange &)> &read
) {
    HNStepMeshFree(mesh);

    occ::handle<XCAFApp_Application> application = XCAFApp_Application::GetApplication();
    occ::handle<TDocStd_Document> document;
    application->NewDocument("MDTV-XCAF", document);

    occ::handle<CallbackProgress> indicator;
    Message_ProgressRange rootRange;
    if (progress != nullptr) {
        indicator = new CallbackProgress(progress, context);
        rootRange = indicator->Start();
    }
    Message_ProgressScope root(rootRange, nullptr, 10.0);

    if (!read(document, root.Next(6.0))) {
        return false;
    }
    return buildMeshFromDocument(document, mesh, root.Next(4.0));
}

} // namespace

bool HNModelImportData(
    const void *data,
    size_t length,
    HNStepMesh *mesh,
    HNProgressCallback progress,
    void *context
) {
    if (data == nullptr || length == 0 || mesh == nullptr) {
        return false;
    }

    try {
        return importDocument(mesh, progress, context,
            [data, length](occ::handle<TDocStd_Document> &document, const Message_ProgressRange &range) {
                return readSTEPStream(data, length, document, range);
            });
    } catch (const Standard_Failure &) {
        HNStepMeshFree(mesh);
        return false;
    } catch (const std::exception &) {
        HNStepMeshFree(mesh);
        return false;
    } catch (...) {
        HNStepMeshFree(mesh);
        return false;
    }
}

bool HNModelImport(const char *path, int32_t format, HNStepMesh *mesh, HNProgressCallback progress, void *context)
{
    if (path == nullptr || mesh == nullptr) {
        return false;
    }

    try {
        return importDocument(mesh, progress, context,
            [path, format](occ::handle<TDocStd_Document> &document, const Message_ProgressRange &range) {
                return readDocument(path, static_cast<HNModelFormat>(format), document, range);
            });
    } catch (const Standard_Failure &) {
        HNStepMeshFree(mesh);
        return false;
    } catch (const std::exception &) {
        HNStepMeshFree(mesh);
        return false;
    } catch (...) {
        HNStepMeshFree(mesh);
        return false;
    }
}

bool HNModelImportBReps(
    const HNBRepInstance *instances,
    size_t count,
    HNStepMesh *mesh,
    HNProgressCallback progress,
    void *context
) {
    if (instances == nullptr || count == 0 || mesh == nullptr) {
        return false;
    }

    try {
        return importBRepInstances(instances, count, mesh, progress, context);
    } catch (const Standard_Failure &) {
        HNStepMeshFree(mesh);
        return false;
    } catch (const std::exception &) {
        HNStepMeshFree(mesh);
        return false;
    } catch (...) {
        HNStepMeshFree(mesh);
        return false;
    }
}

void HNStepMeshFree(HNStepMesh *mesh)
{
    if (mesh == nullptr) {
        return;
    }

    std::free(mesh->vertices);
    std::free(mesh->indices);
    mesh->vertices = nullptr;
    mesh->indices = nullptr;
    mesh->vertexCount = 0;
    mesh->indexCount = 0;
}
