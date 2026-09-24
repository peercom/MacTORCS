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

class cGrCarCamRoadZoom : public cGrPerspCamera
{
 protected:
    float locfar;
    float locfovy;
    
 public:
    cGrCarCamRoadZoom(class cGrScreen *myscreen, int id, int drawCurr, int drawBG,
		      float fovy, float fovymin, float fovymax,
		      float fnear, float ffar = 1500.0,
		      float myfogstart = 1400.0, float myfogend = 1500.0)
	: cGrPerspCamera(myscreen, id, drawCurr, 1, drawBG, 0, fovy, fovymin,
			 fovymax, fnear, ffar, myfogstart, myfogend) {
	locfar = ffar;
	locfovy = fovy;

	up[0] = 0;
	up[1] = 0;
	up[2] = 1;
    }

    void loadDefaults(char *attr) {
	
   	const int PATHSIZE=1024;
	char path[PATHSIZE];

	snprintf(path, PATHSIZE, "%s/%d", GR_SCT_DISPMODE, screen->getId());
	locfovy = (float)GfParmGetNum(grHandle, path,
				   attr, (char*)NULL, fovydflt);
    }

    void setZoom(int cmd) {
	fovy = locfovy;
	cGrPerspCamera::setZoom(cmd);
	locfovy = fovy;
    }
    
    void update(tCarElt *car, tSituation *s) {
	tdble	dx, dy, dz, dd;
	tRoadCam *curCam;

	curCam = car->_trkPos.seg->cam;
    
	if (curCam == NULL) {
	    eye[0] = grWrldX * 0.5;
	    eye[1] = grWrldY * 0.6;
	    eye[2] = 120;
	} else {
	    eye[0] = curCam->pos.x;
	    eye[1] = curCam->pos.y;
	    eye[2] = curCam->pos.z;
	}
	
	center[0] = car->_pos_X;
	center[1] = car->_pos_Y;
	center[2] = car->_pos_Z;

	dx = center[0] - eye[0];
	dy = center[1] - eye[1];
	dz = center[2] - eye[2];
    
	dd = sqrt(dx*dx+dy*dy+dz*dz);

	fnear = dz - 5;
	if (fnear < 1) {
	    fnear = 1;
	}
	ffar  = dd + locfar;
	fovy = RAD2DEG(atan2(locfovy, dd));
	limitFov();

	speed[0] = 0.0;
	speed[1] = 0.0;
	speed[2] = 0.0;
    }
};

