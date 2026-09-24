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

	if (mirrorCam) {
		mirrorCam->setViewport (scrx, scry, scrw, scrh);
		mirrorCam->setPos (scrx + scrw / 4, scry +  5 * scrh / 6 - scrh / 10, scrw / 2, scrh / 6);
	}