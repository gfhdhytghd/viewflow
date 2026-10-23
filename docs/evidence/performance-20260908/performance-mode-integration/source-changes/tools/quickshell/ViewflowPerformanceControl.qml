import QtQuick
import Quickshell
import Quickshell.Io

Column {
    id: root

    property var shellRoot: null
    property real buttonHeight: 72
    property real cardSpacing: 8
    property string mode: "frame-rate"
    property bool busy: false
    property bool available: false
    readonly property string helper: shellRoot ? shellRoot.configDir + "/quickshell/scripts/viewflow-performance.sh" : ""
    spacing: 8

    function selectMode(nextMode) {
        if (busy || !available || mode === nextMode || !helper) return;
        busy = true;
        action.command = ["bash", helper, "set", nextMode];
        action.running = true;
    }

    Text {
        text: "Linux → Windows"
        color: root.shellRoot ? root.shellRoot.primaryText : "#cdd6f4"
        font.pixelSize: 12
    }

    Row {
        width: root.width
        spacing: root.cardSpacing

        Repeater {
            model: [
                { mode: "frame-rate", label: "帧率优先", icon: "󰓅" },
                { mode: "latency", label: "延迟优先", icon: "󱐋" }
            ]
            delegate: ControlPanelToggle {
                required property var modelData
                width: (root.width - root.cardSpacing) / 2
                height: root.buttonHeight
                shellRoot: root.shellRoot
                icon: modelData.icon
                label: modelData.label
                active: root.mode === modelData.mode
                toggleEnabled: root.available && !root.busy
                onClicked: root.selectMode(modelData.mode)
            }
        }
    }

    PollCommand {
        id: poll
        active: root.visible
        interval: 2000
        command: root.helper ? ["bash", root.helper, "status"] : []
        onUpdated: function(output, exitCode) {
            if (root.busy) return;
            root.available = false;
            if (exitCode !== 0) return;
            try {
                const status = JSON.parse(output);
                if (status.mode === "frame-rate" || status.mode === "latency") {
                    root.mode = status.mode;
                    root.available = true;
                }
            } catch (error) {
                root.available = false;
            }
        }
    }

    Process {
        id: action
        stdout: StdioCollector {}
        stderr: StdioCollector { id: actionError }
        onExited: function(exitCode) {
            root.busy = false;
            poll.refresh();
            if (exitCode !== 0) {
                Quickshell.execDetached(["notify-send", "Viewflow", actionError.text.trim() || "性能模式切换失败"]);
            }
        }
    }
}
