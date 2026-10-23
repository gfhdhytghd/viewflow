import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import "DisplaySnap.js" as DisplaySnap

ColumnLayout {
    id: root
    objectName: "displayLayout"
    required property var displays
    required property bool editable
    required property var translations
    signal positionChanged(string identity, int x, int y)
    function t(text) { return translations[text] || text }
    spacing: 14
    Label {
        Layout.fillWidth: true; wrapMode: Text.Wrap; color: "#656b75"
        text: root.editable ? root.t("拖动屏幕排列位置，或输入坐标微调。主机屏幕固定在原点，位置自动同步到从机。") : root.t("显示器位置由主机统一设置。")
    }
    Label { visible: !root.displays.length; text: root.t("配对后可设置显示器位置。"); color: "#656b75" }
    Rectangle {
        id: canvas
        objectName: "displayCanvas"
        visible: root.displays.length > 0
        Layout.fillWidth: true; Layout.preferredHeight: 250
        color: "#f0f3f8"; radius: 9; border.color: "#e0e2e7"; clip: true
        property var guides: []
        readonly property var bounds: {
            var l=0, top=0, r=1, b=1
            for (var d of root.displays) { l=Math.min(l,d.x); top=Math.min(top,d.y); r=Math.max(r,d.x+d.width); b=Math.max(b,d.y+d.height) }
            return {left:l, top:top, width:r-l, height:b-top}
        }
        readonly property real zoom: Math.min((width-64)/bounds.width, (height-56)/bounds.height)
        readonly property real offsetX: (width-bounds.width*zoom)/2
        readonly property real offsetY: (height-bounds.height*zoom)/2
        Repeater {
            model: root.displays
            delegate: Rectangle {
                id: screen
                objectName: "displayTile-"+modelData.id
                required property var modelData
                property var preview: null
                x: canvas.offsetX+((preview ? preview.x : modelData.x)-canvas.bounds.left)*canvas.zoom
                y: canvas.offsetY+((preview ? preview.y : modelData.y)-canvas.bounds.top)*canvas.zoom
                z: dragger.pressed ? 2 : 0
                width: modelData.width*canvas.zoom; height: modelData.height*canvas.zoom
                color: modelData.host ? "#dbe5f4" : "white"
                border.color: dragger.pressed ? "#0869d8" : "#91a5bf"; border.width: 2; radius: 5
                Column {
                    anchors.centerIn: parent; width: parent.width-12; spacing: 4
                    Label { width: parent.width; text: screen.modelData.name; elide: Text.ElideRight; horizontalAlignment: Text.AlignHCenter; font.pixelSize: 12; color: "#23262c" }
                    Label { width: parent.width; text: screen.modelData.width+" × "+screen.modelData.height; horizontalAlignment: Text.AlignHCenter; font.pixelSize: 11; color: "#656b75" }
                }
                MouseArea {
                    id: dragger
                    preventStealing: true
                    anchors.fill: parent; enabled: root.editable && !screen.modelData.host
                    cursorShape: pressed ? Qt.ClosedHandCursor : Qt.OpenHandCursor
                    property point pressedAt
                    property real rawX: 0
                    property real rawY: 0
                    onPressed: function(mouse) {
                        pressedAt=mapToItem(canvas,mouse.x,mouse.y)
                        rawX=screen.modelData.x; rawY=screen.modelData.y
                    }
                    onPositionChanged: function(mouse) {
                        if (!pressed) return
                        var point=mapToItem(canvas,mouse.x,mouse.y)
                        rawX=screen.modelData.x+(point.x-pressedAt.x)/canvas.zoom
                        rawY=screen.modelData.y+(point.y-pressedAt.y)/canvas.zoom
                        screen.preview=DisplaySnap.snap(screen.modelData,root.displays,rawX,rawY,canvas.zoom,true)
                        canvas.guides=screen.preview.guides
                    }
                    onReleased: {
                        var result=DisplaySnap.snap(screen.modelData,root.displays,rawX,rawY,canvas.zoom,true)
                        canvas.guides=[]
                        if (result.x!==screen.modelData.x || result.y!==screen.modelData.y)
                            root.positionChanged(screen.modelData.id,result.x,result.y)
                        screen.preview=null
                    }
                    onCanceled: { screen.preview=null; canvas.guides=[] }
                }
            }
        }
        Repeater {
            model: canvas.guides
            delegate: Rectangle {
                required property var modelData
                z: 3; color: "#0869d8"
                x: canvas.offsetX+(modelData.x1-canvas.bounds.left)*canvas.zoom
                y: canvas.offsetY+(modelData.y1-canvas.bounds.top)*canvas.zoom
                width: Math.max(1,(modelData.x2-modelData.x1)*canvas.zoom)
                height: Math.max(1,(modelData.y2-modelData.y1)*canvas.zoom)
            }
        }
    }
    Repeater {
        model: root.displays
        delegate: RowLayout {
            required property var modelData
            Layout.fillWidth: true; spacing: 8
            Label { Layout.fillWidth: true; text: modelData.name; elide: Text.ElideRight; color: "#23262c" }
            Label { text: "X"; color: "#656b75" }
            TextField { id: posX; Layout.preferredWidth: 78; text: modelData.x.toString(); enabled: root.editable && !modelData.host; validator: IntValidator { bottom: -100000; top: 100000 } selectByMouse: true; Accessible.name: modelData.name+" X" }
            Label { text: "Y"; color: "#656b75" }
            TextField { id: posY; Layout.preferredWidth: 78; text: modelData.y.toString(); enabled: root.editable && !modelData.host; validator: IntValidator { bottom: -100000; top: 100000 } selectByMouse: true; Accessible.name: modelData.name+" Y" }
            Button {
                visible: root.editable
                opacity: modelData.host ? 0 : 1
                implicitWidth: 36; implicitHeight: 36; hoverEnabled: true
                enabled: !modelData.host && posX.acceptableInput && posY.acceptableInput
                Accessible.name: root.t("应用位置"); ToolTip.text: root.t("应用位置"); ToolTip.visible: hovered
                background: Rectangle { radius: 6; color: "white"; border.color: "#d4d7de" }
                contentItem: Image { source: "apply.svg"; fillMode: Image.Pad; sourceSize.width: 18; sourceSize.height: 18 }
                onClicked: root.positionChanged(modelData.id,parseInt(posX.text),parseInt(posY.text))
            }
        }
    }
    Label { Layout.fillWidth: true; wrapMode: Text.Wrap; color: "#656b75"; font.pixelSize: 12; text: root.t("坐标以逻辑像素计，X 向右、Y 向下。屏幕始终保持贴边，不能孤立或重叠。") }
}
