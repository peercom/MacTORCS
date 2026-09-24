/***************************************************************************

    file                 : grcarlight.cpp
    created              : Fri Mar 22 23:16:44 CET 2002
    copyright            : (C) 2001 by Christophe Guionneau
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


void grUpdateCarlight(tCarElt *car,class cGrPerspCamera *curCam, int disp)
{
	int i = 0;
	ssgVtxTableCarlight	*clight;

	for (i = 0; i < theCarslight[car->index].numberCarlight; i++) {
		if (theCarslight[car->index].lightAnchor->getNumKids() != 0) {
			theCarslight[car->index].lightAnchor->removeKid(theCarslight[car->index].lightCurr[i]);
		}
	}

	for (i = 0; i < theCarslight[car->index].numberCarlight; i++) {
		if (!disp) {
			continue;
		}

		clight = (ssgVtxTableCarlight *)theCarslight[car->index].lightArray[i]->clone(SSG_CLONE_GEOMETRY);
		clight->setCullFace(0);

		clight->transform(grCarInfo[car->index].carPos);
		theCarslight[car->index].lightCurr[i]=clight;
		theCarslight[car->index].lightAnchor->addKid(clight);

		switch (theCarslight[car->index].lightType[i]) {
			case LIGHT_TYPE_BRAKE:
			case LIGHT_TYPE_BRAKE2:
				if (car->_brakeCmd>0) {
					clight->setOnOff(1);
				} else {
					clight->setOnOff(0);
				}
				break;
			case LIGHT_TYPE_FRONT:
				if (car->_lightCmd & RM_LIGHT_HEAD1) {
					clight->setOnOff(1);
				} else {
					clight->setOnOff(0);
				}
				break;
			case LIGHT_TYPE_FRONT2:
				if (car->_lightCmd & RM_LIGHT_HEAD2) {
					clight->setOnOff(1);
				} else {
					clight->setOnOff(0);
				}
				break;
			case LIGHT_TYPE_REAR:
				if ((car->_lightCmd & RM_LIGHT_HEAD1) ||
					(car->_lightCmd & RM_LIGHT_HEAD2)) {
					clight->setOnOff(1);
				} else {
					clight->setOnOff(0);
				}
				break;
			default:
				break;
		}
		clight->setFactor(1);
	}
}
