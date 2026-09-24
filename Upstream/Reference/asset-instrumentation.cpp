// SPDX-License-Identifier: GPL-2.0-only
// Executes original parser with scene-storage adapters, before optional
// SSG flatten/stripify and before any texture loading or graphics calls.
#include "CReference.h"
#include "assets/grloadac.cpp"
#include <sstream>
#include <iomanip>
#include <limits>
int preScene(ssgEntity*){return 1;}
static std::string acJSON;
static void quote(std::ostream &out,const std::string &s){
 out<<'"';for(unsigned char c:s){if(c=='"'||c=='\\')out<<'\\'<<c;else if(c<32)out<<"\\u"<<std::hex<<std::setw(4)<<std::setfill('0')<<int(c)<<std::dec;else out<<c;}out<<'"';
}
template<int N> static void array(std::ostream &out,Array<N> *a){
 out<<'[';bool first=true;if(a)for(auto &v:a->values)for(float f:v){if(!first)out<<',';first=false;out<<f;}out<<']';
}
static void integers(std::ostream &out,ssgIndexArray *a){out<<'[';if(a)for(size_t i=0;i<a->values.size();++i){if(i)out<<',';out<<a->values[i];}out<<']';}
static void state(std::ostream &out,ssgState *s){
 if(!s){out<<"null";return;}out<<"{\"material\":[";bool first=true;
 for(int k:{GL_SPECULAR,GL_EMISSION,GL_AMBIENT_AND_DIFFUSE})for(float v:s->material[k]){if(!first)out<<',';first=false;out<<v;}
 out<<','<<s->shininess<<"],\"texture\":";if(s->texture)quote(out,s->texture->path);else out<<"null";
 int flags=(s->enabled[GL_BLEND]?1:0)|(s->enabled[GL_LIGHTING]?2:0)|(s->enabled[GL_COLOR_MATERIAL]?4:0)|(s->enabled[GL_TEXTURE_2D]?8:0)|(s->enabled[GL_ALPHA_TEST]?16:0)|(s->translucent?32:0);
 out<<",\"flags\":"<<flags<<",\"alphaClamp\":"<<s->alpha<<",\"alphaCare\":"<<s->alphaCare<<'}';
}
static void nodes(std::ostream &out,ssgEntity *e,int parent,int &next){
 int index=next++;if(index)out<<',';out<<"{\"parent\":"<<parent<<",\"kind\":"<<e->kind()<<",\"name\":";quote(out,e->name);
 out<<",\"matrix\":[";if(e->kind()==0){auto *t=static_cast<ssgTransform*>(e);for(int i=0;i<16;++i){if(i)out<<',';out<<(&t->matrix[0][0])[i];}}out<<"],\"mesh\":";
 if(e->kind()==2){auto *m=static_cast<grVtxTable*>(e);
 out<<"{\"primitive\":"<<m->primitive<<",\"vertices\":";array(out,m->vertices);out<<",\"normals\":";array(out,m->normals);out<<",\"uv\":[";
 for(int i=0;i<4;++i){if(i)out<<',';array(out,m->uv[i]);}out<<"],\"colors\":";array(out,m->colors);
 out<<",\"indices\":";integers(out,m->indices);out<<",\"strips\":";integers(out,m->strips);
 out<<",\"indexed\":"<<(m->indices?"true":"false")<<",\"cull\":"<<(m->cull?"true":"false")<<",\"mapCount\":"<<m->numMapLevel<<",\"mapLevel\":"<<m->mapLevel<<",\"states\":[";
 for(int i=0;i<4;++i){if(i)out<<',';state(out,m->states[i]);}out<<"]}";
 }else out<<"null";out<<'}';
 if(e->kind()!=2)for(auto *child:static_cast<ssgBranch*>(e)->children)nodes(out,child,index,next);
}
const char *ref_ac_load_json(const char *path,int car,int units){
 if(!path||strlen(path)>=1024||units<1||units>4)return nullptr;
 ssgLoaderOptions options;isacar=car;usestrip=FALSE;usegroup=FALSE;inGroup=0;isaWindow=0;
 current_flags=-1;last_num_kids=-1;numMapLevel=1;mapLevel=LEVEL0;indexCar=0;usenormal=0;nv=totalnv=totalstripe=0;
 maxTextureUnits=units;t_xmin=t_ymin=999999;t_xmax=t_ymax=-999999;
 auto *root=myssgLoadAC(path,&options);if(!root)return nullptr;
 std::ostringstream out;out<<std::setprecision(std::numeric_limits<float>::max_digits10)<<"{\"nodes\":[";int next=0;nodes(out,root,-1,next);out<<"],\"loaderBounds\":";
 if(t_xmin<=t_xmax && t_ymin<=t_ymax)out<<"{\"minimumX\":"<<t_xmin<<",\"maximumX\":"<<t_xmax<<",\"minimumY\":"<<t_ymin<<",\"maximumY\":"<<t_ymax<<"}";else out<<"null";
 out<<"}";acJSON=out.str();
 delete root;
 ssgDeRefDelete(vertlist);vertlist=nullptr;ssgDeRefDelete(striplist);striplist=nullptr;
 delete[]ntab;ntab=nullptr;delete[]t0tab;t0tab=nullptr;delete[]t1tab;t1tab=nullptr;delete[]t2tab;t2tab=nullptr;delete[]t3tab;t3tab=nullptr;
 delete[]current_tbase;current_tbase=nullptr;delete[]current_ttiled;current_ttiled=nullptr;delete[]current_tskids;current_tskids=nullptr;delete[]current_tshad;current_tshad=nullptr;
 current_branch=nullptr;current_material=nullptr;current_colour=nullptr;current_options=nullptr;
 return acJSON.c_str();
}

// Independent original PLIB matrix/point oracle for renderer hierarchy checks.
void ref_ac_transform(const float *parent,const float *local,const float *point,float *matrix,float *world) {
 sgMat4 p,l,m;sgVec3 v;memcpy(p,parent,sizeof(p));memcpy(l,local,sizeof(l));memcpy(v,point,sizeof(v));
 sgMultMat4(m,p,l);memcpy(matrix,m,sizeof(m));sgXformPnt3(v,m);memcpy(world,v,sizeof(v));
}
