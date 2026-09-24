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

     $Id: ssgEntity.cxx 1954 2004-09-13 11:49:36Z wolfram_kuss $
*/


ssgCullResult ssgEntity::hot_test ( sgVec3 s, sgMat4 m, int test_needed )
{
  /* Height-Off-Terrain Test */
  stats_hot_test++ ;

  if ( !test_needed )
  {
    stats_hot_triv_accept++ ;
    return SSG_INSIDE ;
  }

  sgSphere tmp = *(getBSphere()) ;

  if ( tmp.isEmpty () )
    return SSG_OUTSIDE ;

  tmp . orthoXform ( m ) ;

  float d = sgSquare ( s[0] - tmp.getCenter()[0] ) +
            sgSquare ( s[1] - tmp.getCenter()[1] ) ;

  if ( d > sgSquare ( tmp.getRadius() ) )
  {
    stats_hot_radius_reject++ ;
    return SSG_OUTSIDE ;
  }

  stats_hot_straddle++ ;
  return SSG_STRADDLE ;
}
