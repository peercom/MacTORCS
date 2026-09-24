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

class cGrCarCamRoadFly : public cGrPerspCamera
{
 protected:
    int current;
    float timer;
    float zOffset;
    float gain;
    float damp;
    float offset[3];
    double currenttime;
 public:
    cGrCarCamRoadFly(class cGrScreen *myscreen, int id, int drawCurr, int drawBG,
		     float fovy, float fovymin, float fovymax,
		     float fnear, float ffar = 1500.0,
		     float myfogstart = 1400.0, float myfogend = 1500.0)
	: cGrPerspCamera(myscreen, id, drawCurr, 1, drawBG, 0, fovy, fovymin,
			 fovymax, fnear, ffar, myfogstart, myfogend) {
	up[0] = 0;
	up[1] = 0;
	up[2] = 1;
	timer = 0.0;
	offset[0]=0.0;
	offset[1]=0.0;
	offset[2]=60.0;
	current = -1;
	currenttime = 0.0;
	speed[0] = 0.0;
	speed[1] = 0.0;
	speed[2] = 0.0;
    }
    
    void update(tCarElt *car, tSituation *s) {
	//tRoadCam *curCam;
	float height;
	float dt;

	//curCam = car->_trkPos.seg->cam;

	if (currenttime == 0.0) {
	    currenttime = s->currentTime;
	}
	
	if (currenttime == s->currentTime) {
            return;
        }

        bool reset_camera = false;
        dt = s->currentTime - currenttime;
        currenttime = s->currentTime;
        if (fabs(dt) > 1.0f) { 
            dt = 0.1f; // avoid overflow
            reset_camera = true;
        }

        //timer--;
        if (timer<0.0) {
            reset_camera = true;
        } else {
			timer -= dt;
		}

        if (current != car->index) {
            /* the target car changed */
            zOffset = 50.0;
            current = car->index;
            reset_camera = true;
        } else {
            zOffset = 0.0;
        }

        if ((timer <= 0.0) || (zOffset > 0.0)) {
            timer = 10.0 + (int)(5.0*rand()/(RAND_MAX+1.0));
            offset[0] = -0.5 + (rand()/(RAND_MAX+1.0));
            offset[1] = -0.5 + (rand()/(RAND_MAX+1.0));
            offset[2] = 10.0f + (50.0*rand()/(RAND_MAX+1.0)) + zOffset;
            offset[0] = offset[0]*(offset[2]+1.0);
            offset[1] = offset[1]*(offset[2]+1.0);
            // follow the car more closely when low
            gain = 200.0/(10.0f+offset[2]); 
            damp = 5.0f;
        }


        if (reset_camera) {
			eye[0] = car->_pos_X + 50.0 + (50.0*rand()/(RAND_MAX+1.0));
            eye[1] = car->_pos_Y + 50.0 + (50.0*rand()/(RAND_MAX+1.0));
            eye[2] = car->_pos_Z + 50.0 + (50.0*rand()/(RAND_MAX+1.0));
            speed[0] = speed[1] = speed[2] = 0.0f;
        }
	
        speed[0] += (gain*(offset[0]+car->_pos_X - eye[0]) - speed[0]*damp)*dt;
        speed[1] += (gain*(offset[1]+car->_pos_Y - eye[1]) - speed[1]*damp)*dt;
        speed[2] += (gain*(offset[2]+car->_pos_Z - eye[2]) - speed[2]*damp)*dt;

        eye[0] = eye[0] + speed[0]*dt;
        eye[1] = eye[1] + speed[1]*dt;
        eye[2] = eye[2] + speed[2]*dt;

        center[0] = (car->_pos_X);
        center[1] = (car->_pos_Y);
        center[2] = (car->_pos_Z);

        // avoid going under the scene
        height = grGetHOT(eye[0], eye[1]) + 1.0;
        if (eye[2] < height) {
            timer = 10.0 + (int)(10.0*rand()/(RAND_MAX+1.0));
            offset[2] = height - car->_pos_Z + 1.0;
            eye[2] = height;
        }
	
    }



	void onSelect(tCarElt *car, tSituation *s)
	{
		timer = 0;
		current = -1;
	}

};

