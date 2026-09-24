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

class cGrCarCamRoadNoZoom : public cGrPerspCamera
{
 protected:
    
 public:
    cGrCarCamRoadNoZoom(class cGrScreen *myscreen, int id, int drawCurr, int drawBG,
			float fovy, float fovymin, float fovymax,
			float fnear, float ffar = 1500.0,
			float myfogstart = 1400.0, float myfogend = 1500.0)
	: cGrPerspCamera(myscreen, id, drawCurr, 1, drawBG, 0, fovy, fovymin,
			 fovymax, fnear, ffar, myfogstart, myfogend) {
	up[0] = 0;
	up[1] = 0;
	up[2] = 1;
    }

    void update(tCarElt *car, tSituation *s) {
	tRoadCam *curCam;


	curCam = car->_trkPos.seg->cam;
    
	if (curCam == NULL) {
	    eye[0] = grWrldX * 0.5;
	    eye[1] = grWrldY * 0.6;
	    eye[2] = 120;
	    center[2] = car->_pos_Z;
	} else {
	    eye[0] = curCam->pos.x;
	    eye[1] = curCam->pos.y;
	    eye[2] = curCam->pos.z;
	    center[2] = curCam->pos.z;
	}
	
	center[0] = car->_pos_X;
	center[1] = car->_pos_Y;
	/* center[2] = car->_pos_Z; */

	speed[0] = 0.0;
	speed[1] = 0.0;
	speed[2] = 0.0;
    }
};

