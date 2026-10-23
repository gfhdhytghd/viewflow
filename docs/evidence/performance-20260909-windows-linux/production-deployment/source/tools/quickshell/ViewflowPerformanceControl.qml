import QtQuick

Column {
    id: root
    property var shellRoot: null
    property real buttonHeight: 72
    property real cardSpacing: 8
    spacing: 12

    ViewflowPerformanceSelector {
        width: parent.width
        shellRoot: root.shellRoot
        buttonHeight: root.buttonHeight
        cardSpacing: root.cardSpacing
        title: "Linux → Windows"
        helper: shellRoot ? shellRoot.configDir + "/quickshell/scripts/viewflow-performance.sh" : ""
    }

    ViewflowPerformanceSelector {
        width: parent.width
        shellRoot: root.shellRoot
        buttonHeight: root.buttonHeight
        cardSpacing: root.cardSpacing
        title: "Windows → Linux"
        pollInterval: 5000
        helper: shellRoot ? shellRoot.configDir + "/quickshell/scripts/viewflow-reverse-performance.sh" : ""
    }
}
