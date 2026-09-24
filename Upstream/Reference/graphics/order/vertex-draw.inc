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


void ssgVtxTable::draw ()
{
  if ( ! preDraw () )
    return ;

  if ( _ssgCurrentContext-> stateOverridden () )
     _ssgCurrentContext -> overriddenState () -> apply () ;
  else
  if ( hasState () )
    getState () -> apply () ;

  stats_num_leaves++ ;
  stats_num_vertices += getNumVertices() ;

#ifdef _SSG_USE_DLIST
  if ( dlist )
    glCallList ( dlist ) ;
  else
#endif
    draw_geometry () ;

  if ( postDrawCB != NULL )
    (*postDrawCB)(this) ;
}
