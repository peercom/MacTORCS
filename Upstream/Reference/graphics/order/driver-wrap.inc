
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

	/* Set a selector on the driver */
	char* stmp = strdup("DRIVER");
	ssgBranch *b = (ssgBranch *)carEntity->getByName(stmp);
	free(stmp);

	grCarInfo[index].driverSelector = new ssgSelector;
	if (b) {
		ssgBranch *bp = b->getParent(0);
		bp->addKid(grCarInfo[index].driverSelector);
		grCarInfo[index].driverSelector->addKid(b);
		bp->removeKid(b);
		grCarInfo[index].driverSelector->select(1);
		grCarInfo[index].driverSelectorinsg = true;
	} else {
		grCarInfo[index].driverSelectorinsg = false;
	}