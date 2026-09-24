/***************************************************************************

    file                 : grscene.cpp
    created              : Mon Aug 21 20:13:56 CEST 2000
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


	for (i = 0; i < NB_BG_FACES + 1; i++) {
	    alpha = (float)i * 2 * PI / (float)NB_BG_FACES;
	    texLen = (float)i / (float)NB_BG_FACES;

	    x = BG_DIST * cos(alpha);
	    y = BG_DIST * sin(alpha);
	    
	    vtx[0] = x;
	    vtx[1] = y;
	    vtx[2] = z1;
	    bg_vtx->add(vtx);
	    tex[0] = texLen*4.0;
	    tex[1] = 0;
	    bg_tex->add(tex);

	    vtx[0] = x;
	    vtx[1] = y;
	    vtx[2] = z2;
	    bg_vtx->add(vtx);
	    tex[0] = texLen*4.0;
	    tex[1] = 1.0;
	    bg_tex->add(tex);
	}
