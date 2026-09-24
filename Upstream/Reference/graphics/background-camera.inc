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

void cGrBackgroundCam::update(cGrCamera *curCam)
{
    static float BACKGROUND_FOVY_CUTOFF = 60.0f;
    memcpy(&eye, curCam->getPosv(), sizeof(eye));
    memcpy(&center, curCam->getCenterv(), sizeof(center));
    sgSubVec3(center, center, eye);
    sgSetVec3(eye, 0, 0, 0);
    speed[0]=0.0;
    speed[1]=0.0;
    speed[2]=0.0;
    fovy = curCam->getFovY();
    if (fovy < BACKGROUND_FOVY_CUTOFF) {
        fovy = BACKGROUND_FOVY_CUTOFF;
    }
    memcpy(&up, curCam->getUpv(), sizeof(up));
}

