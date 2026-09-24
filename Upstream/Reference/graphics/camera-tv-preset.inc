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

    /* F11 */
    c++;
    GF_TAILQ_INIT(&cams[c]);
    id = 0;
    cam = new cGrCarCamRoadZoomTVD(myscreen,
				   id,
				   1,	/* drawCurr */
				   1,	/* drawBG  */
				   9.0,	/* fovy */
				   1.0,	/* fovymin */
				   90.0,	/* fovymax */
				   1.0,	/* near */
				   1000.0 * fovFactor,	/* far */
				   500.0 * fovFactor,	/* fog */
				   1000.0 * fovFactor	/* fog */
				   );
    cam->add(&cams[c]);
