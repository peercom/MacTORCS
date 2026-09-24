// SPDX-License-Identifier: GPL-2.0-only
// Test-only entry points into the unchanged original SOLID implementations.
#include "CReference.h"
#include "solid/Box.h"
#include "solid/Simplex.h"
#include "solid/Polygon.h"
#include "solid/Object.h"
#include <memory>
#include <vector>
#include <cmath>
extern Scalar rel_error;
namespace {
struct ShapeInput {
    std::vector<Point> vertices;
    VertexBase base;
    std::vector<unsigned int> indices;
    std::unique_ptr<Convex> shape;
    bool initialize(RefConvexShape in,const RefDoubleVector *points) {
        if (in.kind==0) {
            if (!std::isfinite(in.dimensions.x) || !std::isfinite(in.dimensions.y) || !std::isfinite(in.dimensions.z) ||
                in.dimensions.x<0 || in.dimensions.y<0 || in.dimensions.z<0) return false;
            shape.reset(new Box(in.dimensions.x,in.dimensions.y,in.dimensions.z)); return true;
        }
        if (in.kind<1 || in.kind>2 || in.vertexCount<1 || in.vertexCount>65536 || !points) return false;
        for (int i=0;i<in.vertexCount;++i) {
            vertices.emplace_back(points[i].x,points[i].y,points[i].z); indices.push_back(i);
        }
        base = VertexBase(vertices.data());
        if (in.kind==1) shape.reset(new Simplex(base,in.vertexCount,indices.data()));
        else shape.reset(new Polygon(base,in.vertexCount,indices.data()));
        return true;
    }
};
Transform transform(RefConvexTransform in) {
    double m[16] = {in.rowX.x,in.rowY.x,in.rowZ.x,0,in.rowX.y,in.rowY.y,in.rowZ.y,0,
        in.rowX.z,in.rowY.z,in.rowZ.z,0,in.origin.x,in.origin.y,in.origin.z,1};
    return Transform(m);
}
RefDoubleVector refVector(const Tuple3 &v) { return {v[0],v[1],v[2]}; }
}
int ref_convex_support(RefConvexShape shape,const RefDoubleVector *vertices,const RefDoubleVector *directions,int count,RefDoubleVector *outputs) {
    if (!directions || !outputs || count<1 || count>20000) return 0;
    ShapeInput input; if (!input.initialize(shape,vertices)) return 0;
    for (int i=0;i<count;++i) outputs[i] = refVector(input.shape->support(Vector(directions[i].x,directions[i].y,directions[i].z)));
    return 1;
}
int ref_convex_query(RefConvexShape a,const RefDoubleVector *verticesA,RefConvexShape b,const RefDoubleVector *verticesB,
    RefConvexTransform first,RefConvexTransform second,int mode,RefDoubleVector axis,double tolerance,RefConvexResult *out) {
    if (!out || mode<0 || mode>4 || !std::isfinite(tolerance) || tolerance<0) return 0;
    ShapeInput sa,sb; if (!sa.initialize(a,verticesA) || !sb.initialize(b,verticesB)) return 0;
    const auto ta = transform(first), tb = transform(second);
    Vector v(axis.x,axis.y,axis.z); Point pa(1,2,3),pb(4,5,6);
    const auto previous = rel_error; rel_error = tolerance;
    if (mode==0) out->hit = intersect(*sa.shape,*sb.shape,ta,tb,v);
    else if (mode==1) out->hit = common_point(*sa.shape,*sb.shape,ta,tb,v,pa,pb);
    else if (mode==2) { closest_points(*sa.shape,*sb.shape,ta,tb,pa,pb); out->hit = 1; }
    else if (mode==3) out->hit = intersect(*sa.shape,*sb.shape,tb,v);
    else out->hit = common_point(*sa.shape,*sb.shape,tb,v,pa,pb);
    rel_error = previous;
    out->axis = refVector(v); out->firstPoint = refVector(pa); out->secondPoint = refVector(pb);
    out->probeFirst = refVector(sa.shape->support(Vector(0,0,1))); out->probeSecond = refVector(sb.shape->support(Vector(0,0,1)));
    return 1;
}
int ref_convex_smart_sequence(RefConvexShape a,const RefDoubleVector *verticesA,RefConvexShape b,const RefDoubleVector *verticesB,
    RefConvexPoses initial,const RefConvexPoses *poses,int count,RefConvexResult *outputs) {
    if (!poses || !outputs || count<1 || count>20000) return 0;
    ShapeInput sa,sb; if (!sa.initialize(a,verticesA) || !sb.initialize(b,verticesB)) return 0;
    Object oa(&sa,sa.shape.get()),ob(&sb,sb.shape.get());
    oa.prev = transform(initial.first); ob.prev = transform(initial.second);
    const auto previous = rel_error; rel_error = 0.001;
    for (int i=0;i<count;++i) {
        oa.curr = transform(poses[i].first); ob.curr = transform(poses[i].second);
        Vector v(0,0,0); Point pa(1,2,3),pb(4,5,6);
        auto &out = outputs[i]; out.hit = prev_closest_points(oa,ob,v,pa,pb);
        if (out.hit) v = oa.prev(pa)-ob.prev(pb);
        out.axis = refVector(v); out.firstPoint = refVector(pa); out.secondPoint = refVector(pb);
        if (!out.hit) { oa.proceed(); ob.proceed(); }
    }
    rel_error = previous; return 1;
}

namespace {
Transform affineInput(RefAffineInput in) {
    Transform t; if (in.mode & 8) t = transform(in.matrix); else t.setIdentity();
    if (in.mode & 1) t.translate(Vector(in.translation.x,in.translation.y,in.translation.z));
    if (in.mode & 2) t.rotate(Quaternion(in.quaternion.x,in.quaternion.y,in.quaternion.z,in.quaternionW));
    if (in.mode & 4) t.scale(in.scale.x,in.scale.y,in.scale.z);
    return t;
}
RefConvexTransform affineOutput(const Transform &t) {
    return {refVector(t.getBasis()[0]),refVector(t.getBasis()[1]),refVector(t.getBasis()[2]),refVector(t.getOrigin())};
}
}
int ref_affine_query(RefAffineInput first,RefAffineInput second,RefConvexTransform *outputs) {
    if (!outputs) return 0;
    const Transform a = affineInput(first), b = affineInput(second);
    Transform inv,product,relative; inv.invert(a); product.mult(a,b); relative.multInverseLeft(a,b);
    outputs[0] = affineOutput(a); outputs[1] = affineOutput(b); outputs[2] = affineOutput(inv);
    outputs[3] = affineOutput(product); outputs[4] = affineOutput(relative); return 1;
}

#include "solid/Complex.h"
#include "solid/BBox.h"
int ref_complex_sequence(const RefConvexShape *primitives,const RefDoubleVector *vertices,int primitiveCount,
    RefConvexShape other,const RefDoubleVector *otherVertices,RefAffineInput first,RefAffineInput initialSecond,
    const RefAffineInput *poses,int count,int mode,RefComplexResult *outputs) {
    if (!primitives || !vertices || !poses || !outputs || primitiveCount<1 || primitiveCount>65536 || count<1 || count>20000 || mode<0 || mode>1) return 0;
    int total = 0;
    for (int i=0;i<primitiveCount;++i) {
        if (primitives[i].kind<1 || primitives[i].kind>2 || primitives[i].vertexCount<1 || primitives[i].vertexCount>65536) return 0;
        total += primitives[i].vertexCount; if (total>1000000) return 0;
    }
    ShapeInput sb; if (!sb.initialize(other,otherVertices)) return 0;
    std::vector<Point> points; points.reserve(total);
    for (int i=0;i<total;++i) points.emplace_back(vertices[i].x,vertices[i].y,vertices[i].z);
    Complex sa; sa.setBase(points.data());
    std::vector<const Polytope*> polys;
    int offset = 0;
    for (int i=0;i<primitiveCount;++i) {
        std::vector<unsigned> indices;
        for (int j=0;j<primitives[i].vertexCount;++j) indices.push_back(offset++);
        if (primitives[i].kind==1) polys.push_back(new Simplex(sa.getBase(),indices.size(),indices.data()));
        else polys.push_back(new Polygon(sa.getBase(),indices.size(),indices.data()));
    }
    sa.finish(polys.size(),polys.data());
    Object oa(&sa,&sa),ob(&sb,sb.shape.get());
    oa.curr = affineInput(first); oa.proceed(); ob.prev = affineInput(initialSecond);
    const auto previous = rel_error; rel_error = 0.001;
    for (int i=0;i<count;++i) {
        ob.curr = affineInput(poses[i]);
        Vector v(0,0,0); Point pa(1,2,3),pb(4,5,6); ShapePtr primitive = nullptr;
        auto &out = outputs[i]; out.primitive = -1;
        if (mode==0) {
            out.contact.hit = find_prim(sa,*sb.shape,oa.curr,ob.curr,v,primitive);
            if (out.contact.hit) for (int j=0;j<primitiveCount;++j) if (polys[j]==primitive) out.primitive = j;
        } else {
            out.contact.hit = prev_closest_points(oa,ob,v,pa,pb);
            if (out.contact.hit) v = oa.prev(pa)-ob.prev(pb);
            else { oa.proceed(); ob.proceed(); }
        }
        out.contact.axis = refVector(v); out.contact.firstPoint = refVector(pa); out.contact.secondPoint = refVector(pb);
        BBox box = sa.bbox(oa.curr); out.center = refVector(box.getCenter()); out.extent = refVector(box.getExtent());
        out.contact.probeSecond = refVector(sb.shape->support(Vector(0,0,1)));
    }
    rel_error = previous; return 1;
}

namespace {
struct ComplexInput {
    std::vector<Point> points;
    std::vector<const Polytope*> polys;
    std::unique_ptr<Complex> shape;
    bool initialize(const RefConvexShape *primitives,const RefDoubleVector *vertices,int count) {
        if (!primitives || !vertices || count<1 || count>65536) return false;
        int total = 0;
        for (int i=0;i<count;++i) {
            if (primitives[i].kind<1 || primitives[i].kind>2 || primitives[i].vertexCount<1 || primitives[i].vertexCount>65536) return false;
            total += primitives[i].vertexCount; if (total>1000000) return false;
        }
        points.reserve(total);
        for (int i=0;i<total;++i) points.emplace_back(vertices[i].x,vertices[i].y,vertices[i].z);
        shape.reset(new Complex); shape->setBase(points.data());
        int offset = 0;
        for (int i=0;i<count;++i) {
            std::vector<unsigned> indices;
            for (int j=0;j<primitives[i].vertexCount;++j) indices.push_back(offset++);
            if (primitives[i].kind==1) polys.push_back(new Simplex(shape->getBase(),indices.size(),indices.data()));
            else polys.push_back(new Polygon(shape->getBase(),indices.size(),indices.data()));
        }
        shape->finish(polys.size(),polys.data()); return true;
    }
    int index(ShapePtr p) const {
        for (unsigned i=0;i<polys.size();++i) if (polys[i]==p) return i;
        return -1;
    }
};
}
int ref_complex_pair_sequence(const RefConvexShape *firstPrimitives,const RefDoubleVector *firstVertices,int firstCount,
    const RefConvexShape *secondPrimitives,const RefDoubleVector *secondVertices,int secondCount,
    RefAffineInput first,RefAffineInput initialSecond,const RefAffineInput *poses,int count,int mode,RefComplexPairResult *outputs) {
    if (!poses || !outputs || count<1 || count>20000 || mode<0 || mode>1) return 0;
    ComplexInput a,b;
    if (!a.initialize(firstPrimitives,firstVertices,firstCount) || !b.initialize(secondPrimitives,secondVertices,secondCount)) return 0;
    Object oa(&a,a.shape.get()),ob(&b,b.shape.get());
    oa.curr = affineInput(first); oa.proceed(); ob.prev = affineInput(initialSecond);
    const auto previous = rel_error; rel_error = 0.001;
    for (int i=0;i<count;++i) {
        ob.curr = affineInput(poses[i]);
        Vector v(0,0,0); Point pa(1,2,3),pb(4,5,6); ShapePtr sa = nullptr,sb = nullptr;
        auto &out = outputs[i]; out.firstPrimitive = -1; out.secondPrimitive = -1;
        if (mode==0) {
            out.contact.hit = find_prim(*a.shape,*b.shape,oa.curr,ob.curr,v,sa,sb);
            if (out.contact.hit) { out.firstPrimitive = a.index(sa); out.secondPrimitive = b.index(sb); }
        } else {
            out.contact.hit = prev_closest_points(oa,ob,v,pa,pb);
            if (out.contact.hit) v = oa.prev(pa)-ob.prev(pb);
            else { oa.proceed(); ob.proceed(); }
        }
        out.contact.axis = refVector(v); out.contact.firstPoint = refVector(pa); out.contact.secondPoint = refVector(pb);
    }
    rel_error = previous; return 1;
}
