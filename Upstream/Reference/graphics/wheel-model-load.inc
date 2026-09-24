
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

	// Create wheels for 4 speeds (stillstanding - fast --> motion blur, look at the texture).
	for (j = 0; j < 4; j++) {
		ssgBranch *whl_branch = new ssgBranch;
		ssgEntity *whl3d = 0;

		// load speed-dependant 3D wheels if available and if detailed wheels are desired.
		// wheel data files are located in the wheels directory. first set directory.
		if (grUseDetailedWheels == DETAILED) {
			const int bufsize = 1024;
			char buf[bufsize];
			const char* wheel_dir = GfParmGetStr(car->_carHandle, SECT_GROBJECTS, PRM_WHEEL_3D_DIR, 0);
			if (wheel_dir != 0) {
				snprintf(buf, bufsize, "wheels/%s", wheel_dir);
				ssgModelPath(buf);
				ssgTexturePath(buf);
			}
			
			// set basename for wheel file 0..3 gets appended
			const char* wheel_obj = GfParmGetStr(car->_carHandle, SECT_GROBJECTS, PRM_WHEEL_3D, 0);
			if (wheel_obj != 0 && wheel_dir != 0) {
				snprintf(buf, bufsize, "%s%d.acc", wheel_obj, j);
				whl3d = grssgCarLoadAC3D(buf, NULL, car->index);
			}
		}
		
