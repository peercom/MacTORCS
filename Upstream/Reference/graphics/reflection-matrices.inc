/***************************************************************************

    file                 : grvtxtable.cpp
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

	tdble ttx = 0;
	tdble tty = 0;
	tdble ttz = 0;
	sgMat4 mat;
	sgVec3 axis;

	TRACE_GL("draw_geometry_for_a_car: start");

	if (mapLevelBitmap <= LEVELC2) {
		/* UP Vector for OpenGl */
		axis[0] = 0;
		axis[1] = 0;
		axis[2] = 1;

		glActiveTextureARB(GL_TEXTURE2_ARB);
		sgMakeRotMat4(mat, grCarInfo[indexCar].envAngle, axis);
		glMatrixMode(GL_TEXTURE);
		glLoadIdentity();
		glMultMatrixf((float *)mat);
		glMatrixMode(GL_MODELVIEW);
		grEnvShadowState->apply(2);
	}

	grEnvState->apply(1);
	glActiveTextureARB(GL_TEXTURE1_ARB);
	glEnable(GL_TEXTURE_2D);
	glMatrixMode(GL_TEXTURE);
	glLoadIdentity();
	ttx = grCarInfo[indexCar].distFromStart/50;
	sgMakeTransMat4(mat, ttx, tty, ttz);
	glMultMatrixf((float *)mat);
	glMatrixMode(GL_MODELVIEW);

