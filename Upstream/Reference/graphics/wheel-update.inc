
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

	/* wheels */
	for (i = 0; i < 4; i++) {
		float	*clr;

		sgSetCoord(&wheelpos, car->priv.wheel[i].relPos.x, car->priv.wheel[i].relPos.y, car->priv.wheel[i].relPos.z,
					RAD2DEG(car->priv.wheel[i].relPos.az), RAD2DEG(car->priv.wheel[i].relPos.ax), 0);
		grCarInfo[index].wheelPos[i]->setTransform(&wheelpos);
		sgSetCoord(&wheelpos, 0, 0, 0, 0, 0, RAD2DEG(car->priv.wheel[i].relPos.ay));
		grCarInfo[index].wheelRot[i]->setTransform(&wheelpos);
		for (j = 0; j < 3; j++) {
			if (fabs(car->_wheelSpinVel(i)) < maxVel[j]) 
				break;
		}
		grCarInfo[index].wheelselector[i]->select(1<<j);
		clr = grCarInfo[index].brkColor[i]->get(0);
		clr[0] = 0.1 + car->_brakeTemp(i) * 1.5;
		clr[1] = 0.1 + car->_brakeTemp(i) * 0.3;
		clr[2] = 0.1 - car->_brakeTemp(i) * 0.3;
	}

