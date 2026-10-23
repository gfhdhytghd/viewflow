// Coordinates are logical display pixels; tolerance stays constant on the canvas.
function overlap(a, b) {
    return a.x < b.x+b.width && a.x+a.width > b.x && a.y < b.y+b.height && a.y+a.height > b.y;
}
function snap(moving, screens, x, y, zoom, settle) {
    var tolerance = 14 / Math.max(zoom, 0.001);
    var others = screens.filter(function(d) { return d.id !== moving.id; });
    var best = null;
    function candidate(d, axis, edge, px, py) {
        var force = settle;
        if (!force && Math.abs((axis === "x" ? x : y)-edge) > tolerance) return;
        if (axis === "x") {
            py=y;
            if (force) py=Math.max(d.y-moving.height+Math.min(64,moving.height,d.height),Math.min(py,d.y+d.height-Math.min(64,moving.height,d.height)));
            if (py >= d.y+d.height || py+moving.height <= d.y) return;
        } else {
            px=x;
            if (force) px=Math.max(d.x-moving.width+Math.min(64,moving.width,d.width),Math.min(px,d.x+d.width-Math.min(64,moving.width,d.width)));
            if (px >= d.x+d.width || px+moving.width <= d.x) return;
        }
        px=Math.round(px); py=Math.round(py);
        var placed={x:px,y:py,width:moving.width,height:moving.height};
        if (others.some(function(other) { return overlap(placed,other); })) return;
        var score=(px-x)*(px-x)+(py-y)*(py-y);
        var key=d.id+axis+edge;
        if (best && (score > best.score || (score === best.score && key >= best.key))) return;
        best={x:px,y:py,score:score,key:key,guides:[]};
        var contact=axis === "x" ? (px===d.x+d.width ? px : d.x) : (py===d.y+d.height ? py : d.y);
        best.guides.push(axis === "x" ? {x1:contact,y1:Math.min(py,d.y),x2:contact,y2:Math.max(py+moving.height,d.y+d.height)} : {x1:Math.min(px,d.x),y1:contact,x2:Math.max(px+moving.width,d.x+d.width),y2:contact});
        if (axis === "x") {
            for (var k=0;k<3;++k) {
                var line=py+moving.height*k/2;
                if (Math.abs(line-(d.y+d.height*k/2)) < 0.51) best.guides.push({x1:Math.min(px,d.x),y1:line,x2:Math.max(px+moving.width,d.x+d.width),y2:line});
            }
        } else {
            for (var k=0;k<3;++k) {
                var line=px+moving.width*k/2;
                if (Math.abs(line-(d.x+d.width*k/2)) < 0.51) best.guides.push({x1:line,y1:Math.min(py,d.y),x2:line,y2:Math.max(py+moving.height,d.y+d.height)});
            }
        }
    }
    for (var i=0;i<others.length;++i) {
        var d=others[i];
        candidate(d,"x",d.x+d.width,d.x+d.width,y);
        candidate(d,"x",d.x-moving.width,d.x-moving.width,y);
        candidate(d,"y",d.y+d.height,x,d.y+d.height);
        candidate(d,"y",d.y-moving.height,x,d.y-moving.height);
    }
    return best || {x:Math.round(x),y:Math.round(y),guides:[]};
}
