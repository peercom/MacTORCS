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

	if (mapLevelBitmap <= LEVELC3 && grEnvShadowStateOnCars) {
		tdble xxx = (grCarInfo[indexCar].px-shad_xmin)/(shad_xmax-shad_xmin);
		tdble yyy = (grCarInfo[indexCar].py-shad_ymin)/(shad_ymax-shad_ymin);

		/* UP Vector for OpenGl */
		axis[0]=0;
		axis[1]=0;
		axis[2]=1;

		mat2[0][0] = grCarInfo[indexCar].sx;
		mat2[0][1] = 0;
		mat2[0][2] = 0;
		mat2[0][3] = 0 ;

		mat2[1][0] = 0;
		mat2[1][1] = grCarInfo[indexCar].sy;
		mat2[1][2] = 0;
		mat2[1][3] = 0 ;

		mat2[2][0] = 0;
		mat2[2][1] = 0;
		mat2[2][2] = 1;
		mat2[2][3] = 0 ;


		mat2[3][0] = 0;
		mat2[3][1] = 0;
		mat2[3][2] = 0;
		mat2[3][3] = 1;


		glActiveTextureARB(GL_TEXTURE3_ARB);
		sgMakeRotMat4(mat, grCarInfo[indexCar].envAngle, axis);
		glMatrixMode(GL_TEXTURE);
		glLoadIdentity();

		sgMakeTransMat4(mat4, xxx, yyy, 0);
		glMultMatrixf((float *)mat4);

		glMultMatrixf((float *)mat);
		glMultMatrixf((float *)mat2);

		glMatrixMode(GL_MODELVIEW);
		grEnvShadowStateOnCars->apply(3);
	}
