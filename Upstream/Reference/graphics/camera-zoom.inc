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

void cGrPerspCamera::setZoom(int cmd)
{
	const int BUFSIZE=256;
	char buf[BUFSIZE];
	const int PATHSIZE=1024;
	char path[PATHSIZE];


	switch(cmd) {
		case GR_ZOOM_IN:
			if (fovy > 2) {
				fovy--;
			} else {
				fovy /= 2.0;
			}
			if (fovy < fovymin) {
				fovy = fovymin;
			}
			break;

		case GR_ZOOM_OUT:
			fovy++;
			if (fovy > fovymax) {
				fovy = fovymax;
			}
			break;

		case GR_ZOOM_MAX:
			fovy = fovymax;
			break;

		case GR_ZOOM_MIN:
			fovy = fovymin;
			break;

		case GR_ZOOM_DFLT:
			fovy = fovydflt;
			break;
	}

	limitFov();

	snprintf(buf, BUFSIZE, "%s-%d-%d", GR_ATT_FOVY, screen->getCurCamHead(), getId());
	snprintf(path, PATHSIZE, "%s/%d", GR_SCT_DISPMODE, screen->getId());
	GfParmSetNum(grHandle, path, buf, (char*)NULL, (tdble)fovy);
	GfParmWriteFile(NULL, grHandle, "Graph");
}

