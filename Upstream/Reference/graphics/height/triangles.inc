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


void ssgVtxTable::getTriangle ( int n, short *v1, short *v2, short *v3 )
{
  switch ( getPrimitiveType () )
  {
    case GL_POLYGON :
    case GL_TRIANGLE_FAN :
      *v1 =  0  ;
      *v2 = n+1 ;
      *v3 = n+2 ;
      return ;

    case GL_TRIANGLES :
      *v1 = n*3 ;
      *v2 = n*3+1 ;
      *v3 = n*3+2 ;
      return ;

    case GL_TRIANGLE_STRIP :
    case GL_QUAD_STRIP :
      if ( n & 1 )
      {
        *v3 =  n  ;
        *v2 = n+1 ;
        *v1 = n+2 ;
      }
      else
      {
        *v1 =  n  ;
        *v2 = n+1 ;
        *v3 = n+2 ;
      }
      return ;

    case GL_QUADS :
      *v1 = n*2 + 0 ;
      *v2 = n*2 + 1 ;
      *v3 = n*2 + 2 - (n&1)*4 ;
      return ;

    default : return ;
  }
}
