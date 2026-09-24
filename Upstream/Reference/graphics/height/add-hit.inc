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

     $Id: ssgIsect.cxx 1719 2002-10-26 19:00:56Z sjbaker $
*/


void _ssgAddHit ( ssgLeaf *l, int trinum, sgMat4 mat, sgVec4 pl )
{
  if ( next_hit + 1 >= MAX_HITS )
    return ;

  ssgHit *h = & hitlist [ next_hit++ ] ;

  h -> leaf = l ;
  h -> triangle = trinum ;

  h -> num_entries = (next_path>=SSG_MAXPATH) ? SSG_MAXPATH : next_path ;
  memcpy ( h -> path, pathlist, h->num_entries * sizeof ( ssgEntity * ) ) ;

  sgCopyMat4 ( h -> matrix, mat ) ;
  sgCopyVec4 ( h -> plane, pl ) ;
}
