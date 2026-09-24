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

cGrCarCamMirror::~cGrCarCamMirror ()
{
    glDeleteTextures (1, &tex);
    delete viewCam;
}


void cGrCarCamMirror::limitFov(void) {
    fovy = 90.0 / screen->getViewRatio();
}


void cGrCarCamMirror::update(tCarElt *car, tSituation * /* s */)
{
    sgVec3 P, p;

    P[0] = car->_bonnetPos_x;
    P[1] = car->_bonnetPos_y;
    P[2] = car->_bonnetPos_z;
    sgXformPnt3(P, car->_posMat);
	
    eye[0] = P[0];
    eye[1] = P[1];
    eye[2] = P[2];
	
    p[0] = car->_bonnetPos_x - 30.0;
    p[1] = car->_bonnetPos_y;
    p[2] = car->_bonnetPos_z;
    sgXformPnt3(p, car->_posMat);

    center[0] = p[0];
    center[1] = p[1];
    center[2] = p[2];

    up[0] = car->_posMat[2][0];
    up[1] = car->_posMat[2][1];
    up[2] = car->_posMat[2][2];
}


void cGrCarCamMirror::setViewport(int x, int y, int w, int h)
{
	vpx = x;
	vpy = y;
	vpw = w;
	vph = h;

	if (viewCam) {
		delete viewCam;
	}
	viewCam = new cGrOrthoCamera(screen, x,  x + w, y, y + h);
	limitFov();
}


void cGrCarCamMirror::setPos (int x, int y, int w, int h)
{
    mx = x;
    my = y;
    mw = w;
    mh = h;

    // round up texture size to next power of two
    tw = GfNearestPow2(w);
    th = GfNearestPow2(h);
    if (tw < w) {
		tw *= 2;
	}
    if (th < h) {
		th *= 2;
	}

    // Create texture object.
    glBindTexture(GL_TEXTURE_2D, tex);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
    glReadBuffer(GL_BACK);

    glCopyTexImage2D(GL_TEXTURE_2D,
		      0, // map level,
		      GL_RGB, // internal format,
		      0, 0, tw, th,
		      0 ); // border

    tsu = (float) mw / tw;
    teu = 0.0;
    tsv = 0.0;
    tev = (float) mh / th;
}


void cGrCarCamMirror::activateViewport (void)
{
    glViewport(vpx, vpy, vpw, vph);

    // Enable scissor test to conserve graphics memory bandwidth.
    glEnable(GL_SCISSOR_TEST);
    glScissor(vpx + (vpw - mw)/2, vpy + (vph - mh)/2, mw, mh);
}

void cGrCarCamMirror::store (void)
{
	glDisable(GL_SCISSOR_TEST);

	glBindTexture(GL_TEXTURE_2D, tex);
	glReadBuffer(GL_BACK);

	// NVidia recommends to NOT use glCopyTexImage2D for performance reasons.
	glCopyTexSubImage2D(GL_TEXTURE_2D, 0, 0, 0,
			    vpx + (vpw - mw)/2,
			    vpy + (vph - mh)/2, mw, mh);
}


void cGrCarCamMirror::display (void)
{
    viewCam->action ();

    glBindTexture (GL_TEXTURE_2D, tex);
    glBegin(GL_TRIANGLE_STRIP);
    {
	glColor4f(1.0, 1.0, 1.0, 1.0);
	glTexCoord2f(tsu, tsv); glVertex2f(mx, my);
	glTexCoord2f(tsu, tev); glVertex2f(mx, my + mh);
	glTexCoord2f(teu, tsv); glVertex2f(mx + mw, my);
	glTexCoord2f(teu, tev); glVertex2f(mx + mw, my + mh);
    }
    glEnd();
}




