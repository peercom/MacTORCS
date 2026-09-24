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

	if (mirrorCam == NULL) {
		mirrorCam = new cGrCarCamMirror(
			this,
			-1,
			0,					// drawCurr
			1,					// drawBG
			90.0,				// fovy
			0.0,				// fovymin
			360.0,				// fovymax
			0.3,				// near
			300.0 * fovFactor,	// far
			200.0 * fovFactor,	// fog1
			300.0 * fovFactor	// fog
		);
	}
	