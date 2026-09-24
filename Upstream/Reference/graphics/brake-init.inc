
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

static ssgTransform *initWheel(tCarElt *car, int wheel_index)
{
	int		i, j, k;
	float	alpha;
	sgVec3	vtx;
	sgVec4	clr;
	sgVec3	nrm;
	sgVec2	tex;
	tdble	b_offset = 0.0f;
	tdble	curAngle = 0.0f;

#define BRK_BRANCH	16
#define BRK_ANGLE	(2.0 * M_PI / (tdble)BRK_BRANCH)
#define BRK_OFFSET	0.2

	switch(wheel_index) {
		case FRNT_RGT:
			curAngle = -(M_PI / 2.0 + BRK_ANGLE);
			b_offset = BRK_OFFSET - car->_tireWidth(wheel_index) / 2.0;
			break;
		case FRNT_LFT:
			curAngle = -(M_PI / 2.0 + BRK_ANGLE);
			b_offset = car->_tireWidth(wheel_index) / 2.0 - BRK_OFFSET;
			break;
		case REAR_RGT:
			curAngle = (M_PI / 2.0 - BRK_ANGLE);
			b_offset = BRK_OFFSET - car->_tireWidth(wheel_index) / 2.0;
			break;
		case REAR_LFT:
			curAngle = (M_PI / 2.0 - BRK_ANGLE);
			b_offset = car->_tireWidth(wheel_index) / 2.0 - BRK_OFFSET;
			break;
	}

	/* hub */
	ssgVertexArray	*brk_vtx = new ssgVertexArray(BRK_BRANCH + 1);
	ssgColourArray	*brk_clr = new ssgColourArray(1);
	ssgNormalArray	*brk_nrm = new ssgNormalArray(1);
	tdble hubRadius;
	
	/* center */
	vtx[0] = vtx[2] = 0.0;
	vtx[1] = b_offset;
	brk_vtx->add(vtx);
	
	hubRadius = car->_brakeDiskRadius(wheel_index) * 0.6;
	for (i = 0; i < BRK_BRANCH; i++) {
		alpha = (float)i * 2.0 * M_PI / (float)(BRK_BRANCH - 1);
		vtx[0] = hubRadius * cos(alpha);
		vtx[1] = b_offset;
		vtx[2] = hubRadius * sin(alpha);
		brk_vtx->add(vtx);
	}
	

	clr[0] = clr[1] = clr[2] = 0.0;
	clr[3] = 1.0;
	brk_clr->add(clr);
	nrm[0] = nrm[2] = 0.0;

	// Make normal point outside to have proper lighting.
	switch(wheel_index) {
		case FRNT_RGT:
		case REAR_RGT:
			nrm[1] = -1.0;
			break;
		case FRNT_LFT:
		case REAR_LFT:
			nrm[1] = 1.0;
			break;
	}

	brk_nrm->add(nrm);

	ssgVtxTable *brk = new ssgVtxTable(GL_TRIANGLE_FAN, brk_vtx, brk_nrm, NULL, brk_clr);
	brk->setCullFace(0);
	brk->setState(commonState);

	ssgTransform *wheel = new ssgTransform;
	wheel->addKid(brk);

	/* Brake disk */
	brk_vtx = new ssgVertexArray(BRK_BRANCH + 4);
	brk_clr = new ssgColourArray(1);
	brk_nrm = new ssgNormalArray(1);

	for (i = 0; i < (BRK_BRANCH / 2 + 2); i++) {
		alpha = curAngle + (float)i * 2.0 * M_PI / (float)(BRK_BRANCH - 1);
		vtx[0] = car->_brakeDiskRadius(wheel_index) * cos(alpha);
		vtx[1] = b_offset;
		vtx[2] = car->_brakeDiskRadius(wheel_index) * sin(alpha);
		brk_vtx->add(vtx);
		vtx[0] = car->_brakeDiskRadius(wheel_index) * cos(alpha) * 0.6;
		vtx[1] = b_offset;
		vtx[2] = car->_brakeDiskRadius(wheel_index) * sin(alpha) * 0.6;
		brk_vtx->add(vtx);
	}
	

	clr[0] = clr[1] = clr[2] = 0.1;
	clr[3] = 1.0;
	brk_clr->add(clr);
	//nrm[0] = nrm[2] = 0.0;
	//nrm[1] = 1.0;
	brk_nrm->add(nrm);
	
	brk = new ssgVtxTable(GL_TRIANGLE_STRIP, brk_vtx, brk_nrm, NULL, brk_clr);
	brk->setCullFace(0);
	brk->setState(brakeState);
	grCarInfo[grCarIndex].brkColor[wheel_index] = brk_clr;

	wheel->addKid(brk);

	/* Brake caliper */
	brk_vtx = new ssgVertexArray(BRK_BRANCH - 4);
	brk_clr = new ssgColourArray(1);
	brk_nrm = new ssgNormalArray(1);

	for (i = 0; i < (BRK_BRANCH / 2 - 2); i++) {
		alpha = - curAngle + (float)i * 2.0 * M_PI / (float)(BRK_BRANCH - 1);
		vtx[0] = (car->_brakeDiskRadius(wheel_index) + 0.02) * cos(alpha);
		vtx[1] = b_offset;
		vtx[2] = (car->_brakeDiskRadius(wheel_index) + 0.02) * sin(alpha);
		brk_vtx->add(vtx);
		vtx[0] = car->_brakeDiskRadius(wheel_index) * cos(alpha) * 0.6;
		vtx[1] = b_offset;
		vtx[2] = car->_brakeDiskRadius(wheel_index) * sin(alpha) * 0.6;
		brk_vtx->add(vtx);
	}
	

	clr[0] = 0.2;
	clr[1] = 0.2;
	clr[2] = 0.2;
	clr[3] = 1.0;
	brk_clr->add(clr);
	//nrm[0] = nrm[2] = 0.0;
	//nrm[1] = 1.0;
	brk_nrm->add(nrm);

	brk = new ssgVtxTable(GL_TRIANGLE_STRIP, brk_vtx, brk_nrm, NULL, brk_clr);
	brk->setCullFace(0);
	brk->setState(commonState);

	wheel->addKid(brk);

	DBG_SET_NAME(wheel, "Wheel", grCarIndex, wheel_index);

	grCarInfo[grCarIndex].wheelPos[wheel_index] = wheel;

