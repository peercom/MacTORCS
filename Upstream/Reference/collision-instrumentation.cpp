// SPDX-License-Identifier: GPL-2.0-only
// Instrument private response callbacks by compiling unchanged collide.cpp once.
// Original copyright and GPL-2.0-or-later notices remain in that source file.
#include "CReference.h"
#include "sim.h"
#include <map>
#include <vector>
namespace {
using WallPolygons = std::vector<std::vector<RefDoubleVector>>;
std::map<DtShapeRef,WallPolygons> capturedWalls;
DtShapeRef captureShape = nullptr;
DtShapeRef captureNewShape() {
    auto shape = dtNewComplexShape(); capturedWalls[shape] = {}; captureShape = shape; return shape;
}
void captureBegin(DtPolyType type) { capturedWalls[captureShape].emplace_back(); dtBegin(type); }
void captureVertex(DtScalar x,DtScalar y,DtScalar z) { capturedWalls[captureShape].back().push_back({x,y,z}); dtVertex(x,y,z); }
void captureDelete(DtShapeRef shape) { capturedWalls.erase(shape); if (captureShape==shape) captureShape = nullptr; dtDeleteShape(shape); }
}
// Observe the exact vertices passed by unchanged buildWalls; original SOLID
// construction still executes. Captures are released with the original shapes.
#define dtNewComplexShape captureNewShape
#define dtBegin captureBegin
#define dtVertex captureVertex
#define dtDeleteShape captureDelete
#include "collide.cpp"
#undef dtNewComplexShape
#undef dtBegin
#undef dtVertex
#undef dtDeleteShape
int ref_fixed_wall_count() { return fixedid; }
int ref_fixed_wall_polygon_count(int wall) {
    if (wall<0 || wall>=static_cast<int>(fixedid)) return -1;
    return capturedWalls.at(fixedobjects[wall]).size();
}
int ref_fixed_wall_vertices(int wall,int polygon,RefDoubleVector *out,int capacity) {
    if (!out || polygon<0 || polygon>=ref_fixed_wall_polygon_count(wall)) return -1;
    const auto &points = capturedWalls.at(fixedobjects[wall])[polygon];
    if (capacity<static_cast<int>(points.size())) return -1;
    for (unsigned i=0;i<points.size();++i) out[i] = points[i];
    return points.size();
}
void ref_call_pair_response(tCar *first, tCar *second, const DtCollData *contact) {
    SimCarCollideResponse(nullptr,first,second,contact);
}
void ref_call_wall_response(tCar *car, const DtCollData *contact, bool wallFirst) {
    int wall;
    if (wallFirst) SimCarWallCollideResponse(&wall,&wall,car,contact);
    else SimCarWallCollideResponse(&wall,car,&wall,contact);
}

#include "solid/Object.h"
#include "solid/Encounter.h"
extern std::map<DtObjectRef,Object*> objectList;
int ref_fixed_pair_query(int firstWall,int secondWall,RefFixedPairResult *out) {
    if (!out || firstWall<0 || secondWall<0 || firstWall>=static_cast<int>(fixedid) || secondWall>=static_cast<int>(fixedid) || firstWall==secondWall) return 0;
    auto a = objectList.find(&fixedobjects[firstWall]), b = objectList.find(&fixedobjects[secondWall]);
    if (a==objectList.end() || b==objectList.end()) return 0;
    Encounter pair(a->second,b->second);
    out->firstWall = pair.obj1==a->second ? firstWall : secondWall;
    out->secondWall = pair.obj1==a->second ? secondWall : firstWall;
    Point pa(1,2,3),pb(4,5,6);
    out->contact.hit = prev_closest_points(*pair.obj1,*pair.obj2,pair.sep_axis,pa,pb);
    out->wouldAccessCar = 0;
    if (out->contact.hit) {
        Vector n = pair.obj1->prev(pa)-pair.obj2->prev(pb);
        out->contact.axis = {n[0],n[1],n[2]};
        // Only inspect the unchanged callback's gate; never call it with a wall
        // masquerading as tCar. This is a diagnostic oracle, not a fake response.
        sgVec2 normalized = {static_cast<float>(n[0]),static_cast<float>(n[1])};
        sgNormaliseVec2(normalized);
        out->wouldAccessCar = !isnan(normalized[0]) && !isnan(normalized[1]);
    }
    out->contact.firstPoint = {pa[0],pa[1],pa[2]}; out->contact.secondPoint = {pb[0],pb[1],pb[2]};
    return 1;
}
