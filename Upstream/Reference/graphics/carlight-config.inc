
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

	snprintf(path, PATHSIZE, "%s/%s", SECT_GROBJECTS, SECT_LIGHT);
	lightNum = GfParmGetEltNb(handle, path);
	for (i = 0; i < lightNum; i++) {
		snprintf(path, PATHSIZE, "%s/%s/%d", SECT_GROBJECTS, SECT_LIGHT, i + 1);
		lightPos[0] = GfParmGetNum(handle, path, PRM_XPOS, NULL, 0);
		lightPos[1] = GfParmGetNum(handle, path, PRM_YPOS, NULL, 0);
		lightPos[2] = GfParmGetNum(handle, path, PRM_ZPOS, NULL, 0);
		lightType = GfParmGetStr(handle, path, PRM_TYPE, "");
		lightTypeNum = LIGHT_NO_TYPE;
		if (!strcmp(lightType, VAL_LIGHT_HEAD1)) {
			lightTypeNum = LIGHT_TYPE_FRONT;
		} else if (!strcmp(lightType, VAL_LIGHT_HEAD2)) {
			lightTypeNum = LIGHT_TYPE_FRONT2;
		} else if (!strcmp(lightType, VAL_LIGHT_BRAKE)) {
			lightTypeNum = LIGHT_TYPE_BRAKE;
		} else if (!strcmp(lightType, VAL_LIGHT_BRAKE2)) {
			lightTypeNum = LIGHT_TYPE_BRAKE2;
		} else if (!strcmp(lightType, VAL_LIGHT_REAR)) {
			lightTypeNum = LIGHT_TYPE_REAR;
		}
		grAddCarlight(car, lightTypeNum, lightPos, GfParmGetNum(handle, path, PRM_SIZE, NULL, 0.2));
	}

