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

     $Id: ssgTransform.cxx 1992 2004-12-01 08:28:05Z wolfram_kuss $
*/


void ssgTransform::hot ( sgVec3 s, sgMat4 m, int test_needed )
{
  if ( ! preTravTests ( &test_needed, SSGTRAV_HOT ) )
    return ;

  int hot_result = hot_test ( s, m, test_needed ) ;

  if ( hot_result == SSG_OUTSIDE )
    return ;

  sgMat4 tmp ;

  sgCopyMat4 ( tmp, m ) ;
  sgPreMultMat4 ( tmp, transform ) ;

  _ssgPushPath ( this ) ;

  for ( ssgEntity *e = getKid ( 0 ) ; e != NULL ; e = getNextKid() )
    e -> hot ( s, tmp, hot_result != SSG_INSIDE ) ;

  _ssgPopPath () ;

  postTravTests ( SSGTRAV_HOT ) ;
}
