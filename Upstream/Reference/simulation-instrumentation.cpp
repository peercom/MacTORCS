// SPDX-License-Identifier: GPL-2.0-only
// Compile the unchanged original source once through this instrumentation unit
// so its private ctrlCheck function is callable without copying its equations.
// simu.cpp retains its original copyright and GPL-2.0-or-later notice.
#include "simu.cpp"
#include "CReference.h"
RefCheckedCommand ref_check_control(RefDriverCommand in, unsigned int flags, float speed, float toRight, float width) {
    tCar car{}; tCarElt element{}; tTrackSeg segment{};
    car.carElt = &element; car.ctrl = &element.ctrl; element._state = flags;
    segment.width = width; car.trkPos.seg = &segment; car.trkPos.toRight = toRight; car.DynGC.vel.x = speed;
    auto &c = *car.ctrl;
    c.accelCmd = in.throttle; c.brakeCmd = in.brake; c.steer = in.steering; c.clutchCmd = in.clutch;
    c.gear = in.gear; c.brakeRepartitionCmd = in.brakeRepartitionClicks;
    ctrlCheck(&car);
    return {{c.accelCmd,c.brakeCmd,c.steer,c.clutchCmd,c.gear,c.brakeRepartitionCmd},car.transmission.clutch.transferValue};
}

void ref_call_remove_car(tCar *car,tSituation *situation) { RemoveCar(car,situation); }
