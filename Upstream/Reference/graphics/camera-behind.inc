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

class cGrCarCamBehind : public cGrPerspCamera
{
    tdble PreA;

 protected:
    float dist;
    float height;
    
 public:
    cGrCarCamBehind(class cGrScreen *myscreen, int id, int drawCurr, int drawBG,
		    float fovy, float fovymin, float fovymax,
		    float mydist, float myHeight, float fnear, float ffar = 1500.0,
		    float myfogstart = 1400.0, float myfogend = 1500.0)
	: cGrPerspCamera(myscreen, id, drawCurr, 1, drawBG, 0, fovy, fovymin,
			 fovymax, fnear, ffar, myfogstart, myfogend) {
	dist = mydist;
	height = myHeight;
	PreA = 0.0;
	up[0] = 0;
	up[1] = 0;
	up[2] = 1;
    }

    void update(tCarElt *car, tSituation *s) {
	tdble A;
	tdble CosA;
	tdble SinA;
	tdble x;
	tdble y;

	A = car->_yaw;
	if (fabs(PreA - A) > fabs(PreA - A + 2*PI)) {
	    PreA += 2*PI;
	} else if (fabs(PreA - A) > fabs(PreA - A - 2*PI)) {
	    PreA -= 2*PI;
	}
	RELAXATION(A, PreA, 10.0);
	CosA = cos(A);
	SinA = sin(A);
	x = car->_pos_X - dist * CosA;
	y = car->_pos_Y - dist * SinA;
    
	eye[0] = x;
	eye[1] = y;
	eye[2] = RtTrackHeightG(car->_trkPos.seg, x, y) + height;
	center[0] = car->_pos_X + (10 - dist) * CosA;
	center[1] = car->_pos_Y + (10 - dist) * SinA;
	center[2] = car->_pos_Z;

	speed[0] = car->pub.DynGCg.vel.x;
	speed[1] = car->pub.DynGCg.vel.y;
	speed[2] = car->pub.DynGCg.vel.z;

    }
};


