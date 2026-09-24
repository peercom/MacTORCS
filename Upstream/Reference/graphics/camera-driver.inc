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

class cGrCarCamInside : public cGrPerspCamera
{
 public:
    cGrCarCamInside(class cGrScreen *myscreen, int id, int drawCurr, int drawBG,
		    float myfovy, float myfovymin, float myfovymax,
		    float myfnear, float myffar = 1500.0,
		    float myfogstart = 800.0, float myfogend = 1500.0)
	: cGrPerspCamera(myscreen, id, drawCurr, 0, drawBG, 1,
			 myfovy, myfovymin, myfovymax,
			 myfnear, myffar, myfogstart, myfogend) {
	up[0] = 0;
	up[1] = 0;
	up[2] = 1;
    }

    void update(tCarElt *car, tSituation *s) {
	sgVec3 P, p;
	
	p[0] = car->_drvPos_x;
	p[1] = car->_drvPos_y;
	p[2] = car->_drvPos_z;
	sgXformPnt3(p, car->_posMat);
	
	eye[0] = p[0];
	eye[1] = p[1];
	eye[2] = p[2];

	P[0] = car->_drvPos_x + 30.0;
	P[1] = car->_drvPos_y;
	P[2] = car->_drvPos_z;
	sgXformPnt3(P, car->_posMat);

	center[0] = P[0];
	center[1] = P[1];
	center[2] = P[2];

	speed[0] =car->pub.DynGCg.vel.x;  
	speed[1] =car->pub.DynGCg.vel.y;  
	speed[2] =car->pub.DynGCg.vel.z;
    }
};


