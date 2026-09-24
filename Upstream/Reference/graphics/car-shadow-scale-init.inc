
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

	/* add wheels */
	for (i = 0; i < 4; i++){
		wheel[i] = initWheel(car, i);
		carBody->addKid(wheel[i]);
	}
	grCarInfo[index].LODSelectMask[0] = 1 << selIndex; /* car mask */
	selIndex++;
	grCarInfo[index].sx=carTrackRatioX;
	grCarInfo[index].sy=carTrackRatioY;
