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


	GLfloat mat_specular[]   = {0.3, 0.3, 0.3, 1.0};
	GLfloat mat_shininess[]  = {50.0};
	GLfloat light_position[] = {0, 0, 200, 0.0};
	GLfloat lmodel_ambient[] = {0.2, 0.2, 0.2, 1.0};
	GLfloat lmodel_diffuse[] = {0.8, 0.8, 0.8, 1.0};
	GLfloat fog_clr[]        = {1.0, 1.0, 1.0, 0.5};

	mat_specular[0] = GfParmGetNum(hndl, TRK_SECT_GRAPH, TRK_ATT_SPEC_R, NULL, mat_specular[0]);
	mat_specular[1] = GfParmGetNum(hndl, TRK_SECT_GRAPH, TRK_ATT_SPEC_G, NULL, mat_specular[1]);
	mat_specular[2] = GfParmGetNum(hndl, TRK_SECT_GRAPH, TRK_ATT_SPEC_B, NULL, mat_specular[2]);

	lmodel_ambient[0] = GfParmGetNum(hndl, TRK_SECT_GRAPH, TRK_ATT_AMBIENT_R, NULL, lmodel_ambient[0]);
	lmodel_ambient[1] = GfParmGetNum(hndl, TRK_SECT_GRAPH, TRK_ATT_AMBIENT_G, NULL, lmodel_ambient[1]);
	lmodel_ambient[2] = GfParmGetNum(hndl, TRK_SECT_GRAPH, TRK_ATT_AMBIENT_B, NULL, lmodel_ambient[2]);

	lmodel_diffuse[0] = GfParmGetNum(hndl, TRK_SECT_GRAPH, TRK_ATT_DIFFUSE_R, NULL, lmodel_diffuse[0]);
	lmodel_diffuse[1] = GfParmGetNum(hndl, TRK_SECT_GRAPH, TRK_ATT_DIFFUSE_G, NULL, lmodel_diffuse[1]);
	lmodel_diffuse[2] = GfParmGetNum(hndl, TRK_SECT_GRAPH, TRK_ATT_DIFFUSE_B, NULL, lmodel_diffuse[2]);

	mat_shininess[0] = GfParmGetNum(hndl, TRK_SECT_GRAPH, TRK_ATT_SHIN, NULL, mat_shininess[0]);

	light_position[0] = GfParmGetNum(hndl, TRK_SECT_GRAPH, TRK_ATT_LIPOS_X, NULL, light_position[0]);
	light_position[1] = GfParmGetNum(hndl, TRK_SECT_GRAPH, TRK_ATT_LIPOS_Y, NULL, light_position[1]);
	light_position[2] = GfParmGetNum(hndl, TRK_SECT_GRAPH, TRK_ATT_LIPOS_Z, NULL, light_position[2]);

