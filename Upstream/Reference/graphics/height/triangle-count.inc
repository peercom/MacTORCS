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


int ssgVtxTable::getNumTriangles ()
{
  switch ( getPrimitiveType () )
  {
    case GL_POLYGON :
    case GL_TRIANGLE_FAN :
      return getNumVertices() - 2 ;

    case GL_TRIANGLES :
      return getNumVertices() / 3 ;

    case GL_TRIANGLE_STRIP :
      return getNumVertices() - 2 ;

    case GL_QUADS :
      return ( getNumVertices() / 4 ) * 2 ;

    case GL_QUAD_STRIP :
      return ( ( getNumVertices() - 2 ) / 2 ) * 2 ;

    case GL_POINTS :
    case GL_LINES :
    case GL_LINE_LOOP :
    case GL_LINE_STRIP :
      return 0;
    default : break ;
  }

  return 0 ;   /* Should never get here...but you never know! */
}
