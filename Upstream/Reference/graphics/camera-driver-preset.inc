/***************************************************************************

    file                 : grcam.cpp
    created              : Mon Aug 21 20:55:32 CEST 2000
    copyright            : (C) 2000 by Eric Espie
    email                : torcs@free.fr
    version              : $Id$

 ***************************************************************************/

/***************************************************************************
 *                                                                         *
 *   This program is free software; you can redistribute it and/or modify  *
 *   it under the terms of the GNU General Public License as published by  *
 *   the Free Software Foundation; either version 2 of the License, or     *
 *   (at your option) any later version.                                   *
 *                                                                         *
 ***************************************************************************/

    /* cam F2 = car inside with car (bonnet view) */
    cam = new cGrCarCamInside(myscreen,
			      id,
			      1,	/* drawCurr */
			      1,	/* drawBG  */
			      67.5,	/* fovy */
			      50.0,	/* fovymin */
			      95.0,	/* fovymax */
			      0.1,	/* near */
			      600.0 * fovFactor,	/* far */
			      300.0 * fovFactor,	/* fog */
			      600.0 * fovFactor	/* fog */
			      );
    cam->add(&cams[c]);
    id++;

