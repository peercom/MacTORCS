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


void ssgVtxTableCarlight::draw_geometry ()
{
	int num_normals = getNumNormals();
	float alpha;
	GLfloat modelView[16];
	sgVec3 A, B, C, D;
	sgVec3 right, up;
	sgVec3 axis;
	sgMat4 mat;
	sgMat4 mat3;
	sgVec3 *vx = (sgVec3 *) vertices->get(0);
	sgVec3 *nm = (sgVec3 *) normals->get(0);

	if (on == 0) {
		return;
	}

	alpha = 0.75f;
	glDepthMask(GL_FALSE);
	glTexEnvf(GL_TEXTURE_ENV, GL_TEXTURE_ENV_MODE, GL_MODULATE);

	glPolygonOffset(-15.0f, -20.0f);
	glEnable(GL_POLYGON_OFFSET_FILL);
	// get the matrix.
	glGetFloatv(GL_MODELVIEW_MATRIX, modelView);

	// get the up and right vector from the matrice view.
	up[0] = modelView[1];
	up[1] = modelView[5];
	up[2] = modelView[9];

	right[0] = modelView[0];
	right[1] = modelView[4];
	right[2] = modelView[8];

	// compute the coordinates of the four points of the quadri.

	// up and right points
	C[0] = right[0] + up[0];
	C[1] = right[1] + up[1];
	C[2] = right[2] + up[2];

	// left and up
	D[0] = -right[0] + up[0];
	D[1] = -right[1] + up[1];
	D[2] = -right[2] + up[2];

	// down and left
	A[0] = -right[0] - up[0];
	A[1] = -right[1] - up[1];
	A[2] = -right[2] - up[2];

	// right and down
	B[0] = right[0] - up[0];
	B[1] = right[1] - up[1];
	B[2] = right[2] - up[2];
	axis[0] = 0;
	axis[1] = 0;
	axis[2] = 1;

	if (maxTextureUnits > 1) {
		glActiveTextureARB (GL_TEXTURE0_ARB);
	}

	sgMakeRotMat4(mat, ((float)rand()/(float)RAND_MAX)*45, axis);
	glMatrixMode(GL_TEXTURE);
	glLoadIdentity ();
	sgMakeTransMat4(mat3, 0.5, 0.5, 0);
	glMultMatrixf((float *)mat3);
	glMultMatrixf((float *)mat);
	sgMakeTransMat4(mat3, -0.5, -0.5, 0);
	glMultMatrixf((float *)mat3);
	glMatrixMode(GL_MODELVIEW);

	glBegin(gltype) ;
	glColor4f(0.8, 0.8, 0.8, alpha);
	if (num_normals == 1) {
		glNormal3fv(nm[0]);
	}
	// the computed coordinates are translated from the smoke position with the x,y,z speed.
	glTexCoord2f(0, 0);
	glVertex3f(vx[0][0] + factor*size*A[0], vx[0][1] + factor*size*A[1], vx[0][2] + factor*size*A[2]);
	glTexCoord2f(0, 1);

	glVertex3f(vx[0][0] + factor*size*B[0], vx[0][1] + factor*size*B[1], vx[0][2] + factor*size*B[2]);
	glTexCoord2f(1, 0);

	glVertex3f(vx[0][0] + factor*size*D[0], vx[0][1] + factor*size*D[1], vx[0][2] + factor*size*D[2]);
	glTexCoord2f(1, 1);

	glVertex3f(vx[0][0]+factor*size*C[0],vx[0][1]+factor*size*C[1], vx[0][2]+factor*size*C[2]);

	glEnd();
	glDisable(GL_POLYGON_OFFSET_FILL);

	if (maxTextureUnits > 1) {
		glActiveTextureARB (GL_TEXTURE0_ARB);
	}

	glMatrixMode(GL_TEXTURE);
	glLoadIdentity();
	glMatrixMode(GL_MODELVIEW);

	glDepthMask(GL_TRUE);
}
