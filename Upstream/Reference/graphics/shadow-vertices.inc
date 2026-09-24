
/***************************************************************************

    file                 : grcar.cpp
    created              : Mon Aug 21 18:24:02 CEST 2000
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

	/* vertices */
#define MULT	1.1
	vtx[2] = 0.0;
	for (i = 0, x = car->_dimension_x * MULT / 2.0; i < GR_SHADOW_POINTS / 2; i++, x -= car->_dimension_x * MULT / (float)(GR_SHADOW_POINTS - 2) * 2.0) {
		vtx[0] = x;
		tex[0] = 1.0 - (float)i / (float)((GR_SHADOW_POINTS - 2) / 2.0);

		vtx[1] = -car->_dimension_y * MULT / 2.0;
		shd_vtx->add(vtx);
		tex[1] = 0.0;
		shd_tex->add(tex);

		vtx[1] = car->_dimension_y * MULT / 2.0;
		shd_vtx->add(vtx);
		tex[1] = 1.0;
		shd_tex->add(tex);

	};

