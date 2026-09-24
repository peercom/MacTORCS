/*
     PLIB - A Suite of Portable Game Libraries
     Copyright (C) 1998,2002  Steve Baker
 
     This library is free software; you can redistribute it and/or
     modify it under the terms of the GNU Library General Public
     License as published by the Free Software Foundation; either
     version 2 of the License, or (at your option) any later version.
 
     This library is distributed in the hope that it will be useful,
     but WITHOUT ANY WARRANTY; without even the implied warranty of
     MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
     Library General Public License for more details.
 
     You should have received a copy of the GNU Library General Public
     License along with this library; if not, write to the Free Software
     Foundation, Inc., 59 Temple Place, Suite 330, Boston, MA  02111-1307 USA
 
     For further information visit http://plib.sourceforge.net

     $Id: ssgVtxTable.cxx 1992 2004-12-01 08:28:05Z wolfram_kuss $
*/


void ssgVtxTable::hot_triangles ( sgVec3 s, sgMat4 m, int /* test_needed */ )
{
  int nt = getNumTriangles () ;

  stats_hot_triangles += nt ;

  for ( int i = 0 ; i < nt ; i++ )
  {
    short v1,  v2,  v3 ;
    sgVec3 vv1, vv2, vv3 ;
    sgVec4 plane ;

    if ( _ssgBackFaceCollisions )
      getTriangle ( i, &v1, &v3, &v2 ) ;
    else
      getTriangle ( i, &v1, &v2, &v3 ) ;

    sgXformPnt3 ( vv1, getVertex(v1), m ) ;
    sgXformPnt3 ( vv2, getVertex(v2), m ) ;
    sgXformPnt3 ( vv3, getVertex(v3), m ) ;

    /*
      Does the X/Y coordinate lie outside the triangle's bbox, or
      does the Z coordinate lie beneath the bbox ?
    */

    if ( ( s[0] < vv1[0] && s[0] < vv2[0] && s[0] < vv3[0] ) ||
         ( s[1] < vv1[1] && s[1] < vv2[1] && s[1] < vv3[1] ) ||
         ( s[0] > vv1[0] && s[0] > vv2[0] && s[0] > vv3[0] ) ||
         ( s[1] > vv1[1] && s[1] > vv2[1] && s[1] > vv3[1] ) ||
         ( s[2] < vv1[2] && s[2] < vv2[2] && s[2] < vv3[2] ) )
      continue ;

    sgMakePlane ( plane, vv1, vv2, vv3 ) ;

    if ( _ssgIsHotTest )
    {
      /* No HOT from upside-down or vertical triangles */

      if ( getCullFace() && plane [ 2 ] <= 0 )
        continue ;

      /* Find the point vertically below the text point
      as it crosses the plane of the polygon */

      float z = sgHeightOfPlaneVec2 ( plane, s ) ;

      /* No HOT from below the triangle */

      if ( z > s[2] )
         continue ;

      /* Outside the vertical extent of the triangle? */

      if ( ( z < vv1[2] && z < vv2[2] && z < vv3[2] ) ||
         ( z > vv1[2] && z > vv2[2] && z > vv3[2] ) )
         continue ;
    }

    /*
      Now it gets messy - the isect point is inside
      the bbox of the triangle - but that's not enough.
      Is it inside the triangle itself?
    */

    float  e1 =  s [0] * vv1[1] -  s [1] * vv1[0] ;
    float  e2 =  s [0] * vv2[1] -  s [1] * vv2[0] ;
    float  e3 =  s [0] * vv3[1] -  s [1] * vv3[0] ;
    float ep1 = vv1[0] * vv2[1] - vv1[1] * vv2[0] ;
    float ep2 = vv2[0] * vv3[1] - vv2[1] * vv3[0] ;
    float ep3 = vv3[0] * vv1[1] - vv3[1] * vv1[0] ;

    float ap = (float) fabs ( ep1 + ep2 + ep3 ) ;
    float ai = (float) ( fabs ( e1 + ep1 - e2 ) +
                         fabs ( e2 + ep2 - e3 ) +
                         fabs ( e3 + ep3 - e1 ) ) ;

    if ( ai > ap * 1.01 )
      continue ;

    _ssgAddHit ( this, i, m, plane ) ;
  }
}
