// SPDX-License-Identifier: GPL-2.0-only
// Compiles verbatim branches from the pinned original human.cpp.
#include "include/CReference.h"
#include "private/tgf.h"
#include "private/car.h"
#include <math.h>
using GfCtrlType=int;
#include "input/pref.h"
float ref_human_axis(int role,float value,float minimum,float maximum,float minimumValue,float deadZone,float gain,float exponent,float speedSensitivity,float speed) {
    tControlCmd cmd[21]{};
    for(auto &c:cmd) { c.min=minimum;c.max=maximum;c.minVal=minimumValue;c.deadZone=deadZone;c.pow=gain;c.sens=exponent;c.spdSens=speedSensitivity;c.val=0; }
    struct {float ax[1];} joystick{{value}};auto *joyInfo=&joystick;
    tCarElt storage{};auto *car=&storage;car->pub.speed=speed;
    tdble ax0=0,leftSteer=0,rightSteer=0,throttle=0;
    if(role==0) {
#include "input/left.inc"
        return leftSteer;
    } else if(role==1) {
#include "input/right.inc"
        return rightSteer;
    } else {
#include "input/pedal.inc"
        return car->_accelCmd;
    }
}
