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

void cGrPerspCamera::loadDefaults(char *attr)
{
	const int BUFSIZE=1024;
	char path[BUFSIZE];
	
	snprintf(path, BUFSIZE, "%s/%d", GR_SCT_DISPMODE, screen->getId());
	fovy = (float)GfParmGetNum(grHandle, path, attr, (char*)NULL, fovydflt);
	limitFov();
}


