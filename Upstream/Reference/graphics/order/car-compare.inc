/***************************************************************************

    file        : grscreen.cpp
    created     : Thu May 15 22:11:03 CEST 2003
    copyright   : (C) 2003 by Eric Espi�                       
    email       : eric.espie@torcs.org   
    version     : $Id$

 ***************************************************************************/

/***************************************************************************
 *                                                                         *
 *   This program is free software; you can redistribute it and/or modify  *
 *   it under the terms of the GNU General Public License as published by  *
 *   the Free Software Foundation; either version 2 of the License, or     *
 *   (at your option) any later version.                                   *
 *                                                                         *
 ***************************************************************************/

/** @file   
    		
    @author	<a href=mailto:eric.espie@torcs.org>Eric Espie</a>
    @version	$Id$
*/

static class cGrPerspCamera *ThedispCam;	/* the display camera */

static int
comparCars(const void *car1, const void *car2)
{
	float d1 = ThedispCam->getDist2(*(tCarElt**)car1);
	float d2 = ThedispCam->getDist2(*(tCarElt**)car2);
	
	if (d1 > d2) {
		return -1;
	} else {
		return 1;
	}
}
