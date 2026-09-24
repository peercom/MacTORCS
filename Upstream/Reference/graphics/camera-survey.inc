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

class cGrCarCamCenter : public cGrPerspCamera
{
 protected:
    float distz;
    float locfar;
    float locfovy;
    
 public:
    cGrCarCamCenter(class cGrScreen *myscreen, int id, int drawCurr, int drawBG,
		    float fovy, float fovymin, float fovymax,
		    float mydistz,
		    float fnear, float ffar = 1500.0,
		    float myfogstart = 1400.0, float myfogend = 1500.0)
	: cGrPerspCamera(myscreen, id, drawCurr, 1, drawBG, 0, fovy, fovymin,
			 fovymax, fnear, ffar, myfogstart, myfogend) {
	distz = mydistz;
	locfar = ffar;
	locfovy = fovy;

	eye[0] = grWrldX * 0.5;
	eye[1] = grWrldY * 0.6;
	eye[2] = distz;

	up[0] = 0;
	up[1] = 0;
	up[2] = 1;
    }
    
    void loadDefaults(char *attr) {
		const int PATHSIZE=1024;
		char path[PATHSIZE];

		snprintf(path, PATHSIZE, "%s/%d", GR_SCT_DISPMODE, screen->getId());
		locfovy = (float)GfParmGetNum(grHandle, path, attr, (char*)NULL, fovydflt);
    }

    void setZoom(int cmd) {
	fovy = locfovy;
	cGrPerspCamera::setZoom(cmd);
	locfovy = fovy;
    }
    
    void update(tCarElt *car, tSituation *s) {
	tdble	dx, dy, dz, dd;
	
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

	speed[0] = 0;
	speed[1] = 0;
	speed[2] = 0;

    }
};

class cGrCarCamLookAt : public cGrPerspCamera
{
 protected:
    
 public:
    cGrCarCamLookAt(class cGrScreen *myscreen, int id, int drawCurr, int drawBG,
		    float fovy, float fovymin, float fovymax,
		    int axis,
		    float eyex, float eyey, float eyez,
		    float centerx, float centery, float centerz,
		    float fnear, float ffar = 1500.0,
		    float myfogstart = 1600.0, float myfogend = 1700.0)
	: cGrPerspCamera(myscreen, id, drawCurr, 1, drawBG, 0, fovy, fovymin,
			 fovymax, fnear, ffar, myfogstart, myfogend) {

	eye[0] = eyex;
	eye[1] = eyey;
	eye[2] = eyez;

	center[0] = centerx;
	center[1] = centery;
	center[2] = centerz;
	
	switch (axis) {
	case 0:
	    up[0] = 0;
	    up[1] = 1;
	    up[2] = 0;
	    break;
	case 1:
	    up[0] = 0;
	    up[1] = -1;
	    up[2] = 0;
	    break;
	case 2:
	    up[0] = 1;
	    up[1] = 0;
	    up[2] = 0;
	    break;
	case 3:
	    up[0] = -1;
	    up[1] = 0;
	    up[2] = 0;
	    break;
	case 4:
	    up[0] = 0;
	    up[1] = 0;
	    up[2] = 1;
	    break;
	case 5:
	    up[0] = 0;
	    up[1] = 0;
	    up[2] = -1;
	    break;
	default:
	    up[0] = 0;
	    up[1] = 0;
	    up[2] = 1;
	    break;
	}
    }

    void update(tCarElt *car, tSituation *s) {
    }
};


