/***************************************************************************

    file                 : grscene.cpp
    created              : Mon Aug 21 20:13:56 CEST 2000
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


	/* Landscape */
	LandAnchor = new ssgBranch;
	TheScene->addKid(LandAnchor);

	/* Pit stops walls */
	PitsAnchor = new ssgBranch;
	TheScene->addKid(PitsAnchor);

	/* Skid Marks */
	SkidAnchor = new ssgBranch;
	TheScene->addKid(SkidAnchor);

	/* Car shadows */
	ShadowAnchor = new ssgBranch;
	TheScene->addKid(ShadowAnchor);

	/* Car lights */
	CarlightAnchor = new ssgBranch;
	TheScene->addKid(CarlightAnchor);

	/* Cars */
	CarsAnchor = new ssgBranch;
	TheScene->addKid(CarsAnchor);

	/* Smoke */
	SmokeAnchor = new ssgBranch;
	TheScene->addKid(SmokeAnchor);

	/* Lens Flares */
	SunAnchor = new ssgBranch;
	TheScene->addKid(SunAnchor);
