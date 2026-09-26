"""Keep a host-anchored, non-overlapping layout joined by real shared edges."""
import copy


def overlaps(a, b):
    return a['x'] < b['x']+b['width'] and a['x']+a['width'] > b['x'] and a['y'] < b['y']+b['height'] and a['y']+a['height'] > b['y']


def touches(a, b):
    return ((a['x']+a['width'] == b['x'] or b['x']+b['width'] == a['x']) and
            min(a['y']+a['height'], b['y']+b['height']) >= max(a['y'], b['y']) + min(64,a['height'],b['height'])) or (
            (a['y']+a['height'] == b['y'] or b['y']+b['height'] == a['y']) and
            min(a['x']+a['width'], b['x']+b['width']) >= max(a['x'], b['x']) + min(64,a['width'],b['width']))


def attach(screen, placed):
    candidates = []
    def add(x,y):
        candidate = dict(screen,x=int(x),y=int(y))
        if any(overlaps(candidate,p) for p in placed): return
        if not any(touches(candidate,p) for p in placed): return
        distance = (x-screen['x'])**2+(y-screen['y'])**2
        candidates.append((distance,int(x),int(y),candidate))
    for other in placed:
        low, high = other['y']-screen['height']+min(64,screen['height'],other['height']), other['y']+other['height']-min(64,screen['height'],other['height'])
        ys = [screen['y'],other['y'],other['y']+other['height']-screen['height']]
        ys += [v for p in placed for v in (p['y']-screen['height'],p['y']+p['height'])]
        for x in (other['x']+other['width'],other['x']-screen['width']):
            for y in ys: add(x,max(low,min(high,y)))
        low, high = other['x']-screen['width']+min(64,screen['width'],other['width']), other['x']+other['width']-min(64,screen['width'],other['width'])
        xs = [screen['x'],other['x'],other['x']+other['width']-screen['width']]
        xs += [v for p in placed for v in (p['x']-screen['width'],p['x']+p['width'])]
        for y in (other['y']+other['height'],other['y']-screen['height']):
            for x in xs: add(max(low,min(high,x)),y)
    if not candidates: raise ValueError('无法找到相接的显示器位置。')
    return min(candidates,key=lambda c:c[:3])[3]


def arrange(displays, identity=None, x=None, y=None):
    screens = copy.deepcopy(displays)
    if not screens:return screens
    host = next(s for s in screens if s['host'])
    host.update(x=0,y=0)
    moving = next((s for s in screens if s['id']==identity and not s['host']),None)
    if moving is not None:moving.update(x=x,y=y)
    placed=[host]
    pending=[s for s in screens if not s['host'] and s is not moving]
    # Preserve the stationary component still connected to the host.
    while True:
        ready=next((s for s in pending if any(touches(s,p) for p in placed) and not any(overlaps(s,p) for p in placed)),None)
        if ready is None:break
        placed.append(ready);pending.remove(ready)
    if moving is not None:placed.append(attach(moving,placed))
    # Moving/removing a bridge must not leave another member isolated.
    for screen in sorted(pending,key=lambda s:s['id']):placed.append(attach(screen,placed))
    positions={s['id']:s for s in placed}
    return [positions[s['id']] for s in screens]
