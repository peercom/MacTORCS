/***************************************************************************

    file                 : grcam.h
    created              : Mon Aug 21 20:55:02 CEST 2000
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

class cGrCarCamMirror : public cGrPerspCamera
{
 protected:
    int		vpx, vpy, vpw, vph;	/* viewport size */
    int		tw, th;			/* texture size */
    int		mx, my, mw, mh;		/* drawing area */
    float	tsu, tsv, teu, tev;	/* texture coord */
    GLuint	tex;			/* texture */
    cGrOrthoCamera *viewCam;
    
 public:
    cGrCarCamMirror(cGrScreen *myscreen, int id, int drawCurr, int drawBG,
		    float myfovy, float myfovymin, float myfovymax,
		    float myfnear, float myffar = 1500.0,
		    float myfogstart = 1400.0, float myfogend = 1500.0)
	: cGrPerspCamera(myscreen, id, drawCurr, 1, drawBG, 1,
			 myfovy, myfovymin, myfovymax,
			 myfnear, myffar, myfogstart, myfogend) {
	glGenTextures (1, &tex);
	limitFov();
	viewCam = NULL;
    }
    virtual ~cGrCarCamMirror ();

    void update (tCarElt *car, tSituation *s);
    void limitFov (void);

    void setViewport (int x, int y, int w, int h);
    void setPos (int x, int y, int w, int h);
    void activateViewport (void);
    void store (void);
    void display (void);
};


