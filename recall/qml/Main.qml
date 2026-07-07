import QtQuick
import QtQuick.Controls.Material
import QtQuick.Layouts

ApplicationWindow {
    id: win
    width: 1200
    height: 800
    visible: true
    title: "Recall  ·  v" + (typeof appVersion !== "undefined" ? appVersion : "?")
    // no WindowSystemMenuHint: drops the titlebar icon's options menu
    // (WM-controlled — KWin on Wayland may ignore it)
    flags: Qt.Window | Qt.WindowTitleHint | Qt.WindowCloseButtonHint
         | Qt.WindowMinimizeButtonHint | Qt.WindowMaximizeButtonHint
    Material.theme: Material.Light
    Material.primary: "#e8eaf6" // indigo 50 — light toolbar, dark text picked automatically
    Material.accent: Material.Indigo
    Material.background: "#fafafa"

    property int currentDocId: -1
    property bool editing: false
    property int editDocId: -1    // -1 while creating a new document
    property int editParentId: -1
    property bool editIsTemplate: false  // creating into the Templates tree?

    // Templates view: swaps the document tree for the tree of template
    // documents (agent instructions), and makes Add/create act on that tree
    property bool templateMode: false

    // right-side assistant chat panel
    property bool chatOpen: false
    property bool chatBusy: false
    property var chatRefs: []   // doc ids @-referenced in the pending message

    // Activity timeline (technical log). Collapsed by default; auto-expands
    // while the agent works, or when the user pins it open.
    property bool activityPinned: false
    property bool activityFull: false   // show untruncated output + a wider panel
    readonly property bool activityExpanded: chatOpen && (chatBusy || activityPinned)
    property string docContent: ""
    property var clarifs: []        // pending clarifications for the open document
    property var clarifyRanges: []  // clarifs + matched {start,end} in the reader text
    property var codeRanges: []     // code block runs {start, text} for copy buttons
    property bool revising: false   // an AI revision request is in flight
    property string reviseError: ""

    // clarification color scheme (matches the request bubble style)
    readonly property color clarifyBg: "#fff8e1"
    readonly property color clarifyBgHover: "#ffecb3"
    readonly property color clarifyBorder: "#f9a825"

    // the one accent every animated element shares — button band, sheens,
    // stream frontier glow — so all motion reads as a single system
    readonly property color animAccent: "#64b5f6"

    readonly property color borderColor: "#c5cae9"

    // unified "work in progress" motion: a soft band of light sweeping left to
    // right; the same duration/rhythm is used by the Revise button's gradient
    component Sheen: Item {
        id: sheenRoot
        property color tint: win.animAccent
        clip: true
        Rectangle {
            id: sheenStrip
            width: Math.max(48, sheenRoot.width * 0.35)
            height: sheenRoot.height * 3
            y: -sheenRoot.height
            rotation: 16
            antialiasing: true
            gradient: Gradient {
                orientation: Gradient.Horizontal
                GradientStop { position: 0.0; color: "transparent" }
                GradientStop { position: 0.5; color: Qt.alpha(sheenRoot.tint, 0.4) }
                GradientStop { position: 1.0; color: "transparent" }
            }
            NumberAnimation on x {
                from: -sheenStrip.width
                to: sheenRoot.width + sheenStrip.width
                duration: 1100
                loops: Animation.Infinite
                running: sheenRoot.visible
            }
        }
    }

    // small underline-less text button used under assistant replies
    component ChatLink: Label {
        id: chatLink
        property bool active: true
        signal clicked()
        font.pixelSize: 12
        font.capitalization: Font.MixedCase
        opacity: active ? 1 : 0.55
        color: chatLinkMA.containsMouse && active ? "#5c6bc0" : "#3949ab"
        MouseArea {
            id: chatLinkMA
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: chatLink.active ? Qt.PointingHandCursor : Qt.ArrowCursor
            onClicked: if (chatLink.active) chatLink.clicked()
        }
    }

    // clickable copy button with a drawn clipboard icon (no emoji font needed);
    // briefly flips to a check after copying
    component CopyIconButton: ToolButton {
        id: copyIcon
        property string payload: ""
        property bool done: false
        implicitWidth: 28
        implicitHeight: 26
        padding: 0
        focusPolicy: Qt.NoFocus
        onClicked: { highlighter.copy(payload); done = true; copyIconReset.restart() }
        Timer { id: copyIconReset; interval: 1200; onTriggered: copyIcon.done = false }
        HoverTip { text: copyIcon.done ? "Copied!" : "Copy" }
        background: Rectangle {
            radius: 4
            color: copyIcon.down ? "#e8eaf6" : copyIcon.hovered ? "#eef0f8" : "transparent"
        }
        contentItem: Item {
            Canvas {
                anchors.centerIn: parent
                width: 15
                height: 15
                // raster render target + synchronous paint so it draws on the
                // software backend (no GL), where the default FBO target is blank
                renderTarget: Canvas.Image
                renderStrategy: Canvas.Immediate
                property color tint: copyIcon.done ? "#2e7d32"
                                   : copyIcon.hovered ? "#3949ab" : "#78909c"
                onTintChanged: requestPaint()
                onPaint: {
                    var ctx = getContext("2d")
                    ctx.reset()
                    ctx.strokeStyle = tint
                    ctx.lineWidth = 1.3
                    ctx.lineJoin = "round"
                    ctx.lineCap = "round"
                    if (copyIcon.done) {
                        ctx.beginPath()
                        ctx.moveTo(3, 8); ctx.lineTo(6.5, 11.5); ctx.lineTo(12.5, 4)
                        ctx.stroke()
                    } else {
                        ctx.strokeRect(5, 5, 8, 8)   // back sheet
                        ctx.strokeRect(2, 2, 8, 8)   // front sheet
                    }
                }
            }
        }
    }

    // tooltip shown above its parent control instead of the default below
    component HoverTip: ToolTip {
        x: (parent.width - width) / 2
        y: -height - 6
        delay: 500
        visible: parent.hovered && text !== ""
    }

    component FmtButton: ToolButton {
        property string tip
        implicitWidth: 40
        implicitHeight: 40
        // never steal focus from the editor: its selection is the operand
        // of every formatting action
        focusPolicy: Qt.NoFocus
        HoverTip { text: parent.tip }
    }

    component DocumentGlyph: Item {
        property bool folder: false
        property bool open: false
        implicitWidth: 16
        implicitHeight: 16

        Rectangle {
            visible: !parent.folder
            x: 2
            y: 1
            width: 11
            height: 14
            radius: 1
            color: "#ffffff"
            border.width: 1
            border.color: "#90caf9"

            Column {
                anchors.centerIn: parent
                spacing: 2
                Repeater {
                    model: 3
                    Rectangle { width: 6; height: 1; color: "#90caf9" }
                }
            }
        }

        Rectangle {
            visible: parent.folder
            x: 1
            y: 5
            width: 14
            height: 10
            radius: 1
            color: parent.open ? "#ffe082" : "#ffca6b"
            border.width: 1
            border.color: "#e0a832"
        }

        Rectangle {
            visible: parent.folder
            x: 2
            y: 3
            width: 7
            height: 4
            radius: 1
            color: "#ffca6b"
            border.width: 1
            border.color: "#e0a832"
        }
    }

    // (re)fetch the open document's content + clarifications from the store
    function loadDoc(id) {
        streaming = false
        var doc = id >= 0 ? store.getDocument(id) : {}
        docContent = doc.id ? doc.content : ""
        clarifs = doc.id ? store.clarificationsFor(id) : []
        Qt.callLater(win.applyHighlights) // after the TextEdit re-parses the markdown
    }

    // Apply an external update to the reader with a soft cross-fade.
    //
    // The reader renders Markdown, which is block-structured: while a code
    // fence, table or heading is only partly present it parses as something
    // completely different, so revealing the new text character by character
    // made the whole document reflow violently. Instead we swap straight to the
    // final (correctly laid-out) content and dissolve a snapshot of the old
    // text over it — the change flows in without any reflow thrashing.
    property bool streaming: false   // retained (inert) for the stream-glow overlay
    property string pendingContent: "" // next text, swapped in at the fade's peak

    function streamTo(newContent) {
        streaming = false
        pendingContent = newContent
        docFade.restart()            // dim → swap → reveal (see the reader's cover)
    }

    // swap in the pending text while the cover is opaque, so the layout change
    // (which would otherwise jump) happens hidden behind the dimmed overlay
    function applyPending() {
        docContent = pendingContent
        Qt.callLater(win.applyHighlights)
    }

    // paint code blocks + clarification quotes in the reader's text document
    function applyHighlights() {
        docView.hoverRange = -1
        if (currentDocId >= 0) {
            var res = highlighter.apply(docView.textDocument, clarifs)
            clarifyRanges = res.clarifs
            codeRanges = res.code
        } else {
            clarifyRanges = []
            codeRanges = []
        }
    }

    function openDoc(id) {
        if (editing)
            return // don't clobber an edit in progress
        currentDocId = id
        loadDoc(id)
        docAppear.restart()
    }

    function startNew(parentId) {
        editDocId = -1
        editParentId = parentId
        editIsTemplate = templateMode  // the active tree decides the kind
        titleField.text = ""
        editor.text = ""
        editing = true
        titleField.forceActiveFocus()
    }

    function startEdit(id) {
        var doc = store.getDocument(id)
        if (!doc.id)
            return
        currentDocId = id
        editDocId = doc.id
        titleField.text = doc.title
        editor.text = doc.content
        editing = true
        editor.forceActiveFocus()
    }

    function saveDoc() {
        var id = editDocId
        if (id < 0) {
            id = store.createDoc(titleField.text, editor.text, editParentId,
                                 win.editIsTemplate)
            if (id < 0)
                return // create failed; stay in the editor
        } else {
            store.updateDoc(id, titleField.text, editor.text)
        }
        editing = false
        openDoc(id)
        // reveal the new document in whichever tree it belongs to
        var m = win.editIsTemplate ? templateModel : docModel
        tree.expandToIndex(m.indexForDoc(id))
    }

    function closeEditor() {
        editing = false
        loadDoc(currentDocId)
    }

    // pick up an external change to the open document: unchanged content just
    // refreshes annotations; new content is swapped in
    function refreshCurrentDoc() {
        if (editing || currentDocId < 0)
            return
        var doc = store.getDocument(currentDocId)
        if (!doc.id) {
            loadDoc(currentDocId)
            return
        }
        clarifs = store.clarificationsFor(currentDocId)
        if (doc.content === docContent) {
            Qt.callLater(applyHighlights)
            return
        }
        streamTo(doc.content)
    }

    // scroll to a clarification's quoted text and select it in the reader
    function locateQuote(quote) {
        var i = docView.getText(0, docView.length).indexOf(quote)
        if (i < 0)
            return
        docView.select(i, i + quote.length)
        flick.contentY = Math.max(0, docView.y + docView.positionToRectangle(i).y - 80)
    }

    // --- markdown formatting helpers for the toolbar ---
    function wrapSel(pre, suf) {
        var s = editor.selectionStart
        var e = editor.selectionEnd
        var sel = editor.getText(s, e)
        editor.remove(s, e)
        editor.insert(s, pre + sel + suf)
        editor.select(s + pre.length, s + pre.length + sel.length)
        editor.forceActiveFocus()
    }

    function linePrefix(pre) {
        var lineStart = editor.text.lastIndexOf("\n", editor.selectionStart - 1) + 1
        editor.insert(lineStart, pre)
        editor.forceActiveFocus()
    }

    // --- assistant chat ---
    function chatScrollEnd() {
        chatList.positionViewAtEnd()
    }

    function techScrollEnd() {
        techList.positionViewAtEnd()
    }

    function sendChat() {
        var t = chatInput.text.trim()
        if (t === "" || win.chatBusy || !(chat && chat.available()))
            return
        mentionPop.close()
        chatModel.append({ kind: "user", text: t })
        chatInput.text = ""
        chat.send(t, win.currentDocId, win.chatRefs)
        win.chatRefs = []
        Qt.callLater(win.chatScrollEnd)
    }

    // append chat text (a whole response or a selection) to the open document;
    // the reader picks up the change through store.changed like any other edit
    function addToCurrentDoc(text) {
        if (win.currentDocId <= 0 || win.editing || !text)
            return false
        var doc = store.getDocument(win.currentDocId)
        if (!doc.id)
            return false
        var body = doc.content
        var sep = body.length === 0 ? "" : (body.charAt(body.length - 1) === "\n" ? "\n" : "\n\n")
        store.updateDoc(win.currentDocId, doc.title, body + sep + text)
        return true
    }

    // --- @-mention: the token being typed at the caret, or null ---
    function mentionToken() {
        var pos = chatInput.cursorPosition
        var text = chatInput.text
        var at = text.lastIndexOf("@", pos - 1)
        if (at < 0)
            return null
        // must start the line or follow whitespace, and hold no space up to caret
        if (at > 0 && !/\s/.test(text.charAt(at - 1)))
            return null
        var frag = text.substring(at + 1, pos)
        if (/\s/.test(frag))
            return null
        return { at: at, query: frag }
    }

    function refreshMentions() {
        var tok = win.mentionToken()
        if (tok === null) {
            mentionPop.close()
            return
        }
        mentionPop.matches = store.searchTitles(tok.query)
        mentionPop.at = tok.at
        if (mentionPop.matches.length > 0) {
            mentionList.currentIndex = 0
            if (!mentionPop.visible)
                mentionPop.open()
        } else {
            mentionPop.close()
        }
    }

    function applyMention(doc) {
        var pos = chatInput.cursorPosition
        var at = mentionPop.at
        var before = chatInput.text.substring(0, at)
        var after = chatInput.text.substring(pos)
        var insert = "@" + doc.title + " "
        chatInput.text = before + insert + after
        chatInput.cursorPosition = before.length + insert.length
        var refs = win.chatRefs.slice()
        if (refs.indexOf(doc.id) < 0)
            refs.push(doc.id)
        win.chatRefs = refs
        mentionPop.close()
        chatInput.forceActiveFocus()
    }

    Connections {
        target: store

        function onChanged() {
            // External MCP writes reload the tree model, but the reader
            // also needs to reload the document that is already open.
            if (!win.editing && win.currentDocId >= 0)
                win.refreshCurrentDoc()
        }
    }

    header: ToolBar {
        Material.elevation: 2
        Label {
            id: appTitleLabel
            text: "Recall"
            font.pixelSize: 20
            font.weight: Font.Medium
            anchors.left: parent.left
            anchors.leftMargin: 16
            anchors.verticalCenter: parent.verticalCenter
        }
        // visible version marker: confirms which build is running even when the
        // window manager hides the title bar
        Label {
            text: "v" + (typeof appVersion !== "undefined" ? appVersion : "?")
            font.pixelSize: 12
            opacity: 0.6
            anchors.left: appTitleLabel.right
            anchors.leftMargin: 8
            anchors.baseline: appTitleLabel.baseline
        }
        ToolButton {
            id: menuBtn
            text: "☰"
            font.pixelSize: 24
            implicitWidth: 48
            implicitHeight: 48
            anchors.right: parent.right
            anchors.rightMargin: 8
            anchors.verticalCenter: parent.verticalCenter
            background: Rectangle {
                radius: width / 2
                color: menuBtn.down ? "#c5cae9" : menuBtn.hovered ? "#dde1f1" : "transparent"
            }
            HoverTip { text: "Settings" }
            onClicked: settingsMenu.popup(menuBtn, 0, menuBtn.height)
            Menu {
                id: settingsMenu
                MenuItem {
                    text: "MCP Server Info"
                    onTriggered: mcpInfoWin.show()
                }
                MenuItem {
                    text: "AI Provider…"
                    onTriggered: aiDialog.open()
                }
            }
        }
        ToolButton {
            id: chatToggleBtn
            implicitWidth: 48
            implicitHeight: 48
            anchors.right: menuBtn.left
            anchors.rightMargin: 4
            anchors.verticalCenter: parent.verticalCenter
            background: Rectangle {
                radius: width / 2
                color: win.chatOpen ? "#c5cae9"
                     : chatToggleBtn.down ? "#c5cae9"
                     : chatToggleBtn.hovered ? "#dde1f1" : "transparent"
            }
            // speech bubble drawn with plain Rectangles rather than a Canvas or an
            // emoji glyph: Canvas needs a GPU/GL backend that some Linux setups
            // (software renderer, headless VMs) lack, which left the icon invisible
            contentItem: Item {
                Item {
                    id: chatIcon
                    width: 24
                    height: 24
                    anchors.centerIn: parent

                    Rectangle {
                        id: bubbleBody
                        x: 2; y: 2
                        width: 20; height: 15
                        radius: 5
                        color: "#3949ab"
                    }
                    // tail: a rotated square poking out of the bottom-left
                    Rectangle {
                        x: 5; y: 13
                        width: 7; height: 7
                        radius: 1
                        rotation: 45
                        color: "#3949ab"
                    }
                    Row {
                        y: 7
                        anchors.horizontalCenter: chatIcon.horizontalCenter
                        spacing: 3
                        Repeater {
                            model: 3
                            delegate: Rectangle { width: 3; height: 3; radius: 1.5; color: "white" }
                        }
                    }
                }
            }
            HoverTip { text: win.chatOpen ? "Hide assistant" : "Chat with the assistant" }
            onClicked: win.chatOpen = !win.chatOpen
        }

        TextField {
            id: searchField
            // viewer area = space between the sidebar and (when open) the chat pane;
            // the extra 56 keeps the field clear of the chat/settings buttons
            readonly property real viewerLeft: sidebar.width
            readonly property real viewerRight: win.width - (win.chatOpen ? chatPane.width : 0)
            width: Math.max(180, Math.min(700, viewerRight - viewerLeft - 112))
            anchors.verticalCenter: parent.verticalCenter
            x: viewerLeft + (viewerRight - viewerLeft - width) / 2
            leftPadding: 12
            rightPadding: 12
            // single flat border instead of the Material underline + outline combo
            background: Rectangle {
                implicitHeight: 40
                radius: 6
                color: "white"
                border.width: 1
                border.color: searchField.activeFocus ? win.Material.accent : win.borderColor
            }
            // plain placeholder instead of Material's floating label (which
            // animates up out of the compact background and clips)
            Label {
                text: "Search documents…"
                visible: searchField.text === ""
                anchors.left: parent.left
                anchors.leftMargin: 12
                anchors.verticalCenter: parent.verticalCenter
                color: "#9fa8da"
            }
            onTextChanged: text !== "" ? searchPopup.open() : searchPopup.close()
            onActiveFocusChanged: if (activeFocus && text !== "") searchPopup.open()

            Popup {
                id: searchPopup
                y: searchField.height + 6
                width: searchField.width
                height: Math.min(420, Math.max(resultsList.contentHeight, 48) + topPadding + bottomPadding)
                padding: 6
                closePolicy: Popup.CloseOnEscape | Popup.CloseOnPressOutside

                // quick slide-down + fade as results appear while typing
                enter: Transition {
                    NumberAnimation { property: "opacity"; from: 0; to: 1; duration: 120; easing.type: Easing.OutCubic }
                    NumberAnimation {
                        property: "y"
                        from: searchField.height - 6
                        to: searchField.height + 6
                        duration: 120
                        easing.type: Easing.OutCubic
                    }
                }
                exit: Transition {
                    NumberAnimation { property: "opacity"; from: 1; to: 0; duration: 100 }
                }

                background: Rectangle {
                    radius: 8
                    color: "white"
                    border.width: 1
                    border.color: win.borderColor
                }

                contentItem: ListView {
                    id: resultsList
                    clip: true
                    implicitHeight: contentHeight
                    model: searchField.text !== "" ? store.search(searchField.text) : []
                    delegate: ItemDelegate {
                        width: resultsList.width
                        onClicked: {
                            searchPopup.close()
                            win.openDoc(modelData.id)
                        }
                        contentItem: ColumnLayout {
                            spacing: 2
                            Label {
                                text: modelData.title
                                font.weight: Font.Medium
                                elide: Text.ElideRight
                                Layout.fillWidth: true
                            }
                            Label {
                                text: modelData.snippet
                                textFormat: Text.StyledText
                                wrapMode: Text.Wrap
                                opacity: 0.6
                                font.pixelSize: 12
                                Layout.fillWidth: true
                            }
                        }
                    }
                    Label {
                        anchors.centerIn: parent
                        visible: resultsList.count === 0
                        text: "No matches"
                        opacity: 0.5
                        padding: 12
                    }
                }
            }
        }
    }

    SplitView {
        anchors.fill: parent

        Rectangle {
            id: sidebar
            SplitView.preferredWidth: 300
            SplitView.minimumWidth: 180
            color: Material.background

            ColumnLayout {
                anchors.fill: parent
                spacing: 0

                Button {
                    Layout.fillWidth: true
                    Layout.margins: 8
                    Layout.bottomMargin: 4
                    Layout.preferredHeight: 42
                    text: win.templateMode ? "＋ Add template" : "＋ Add document"
                    implicitHeight: 42
                    font.capitalization: Font.MixedCase
                    font.weight: Font.Medium
                    enabled: !win.editing
                    onClicked: win.startNew(-1)
                    HoverTip {
                        text: win.templateMode
                              ? "Adds a top-level template — right-click a template in the tree to add a child under it"
                              : "Adds a top-level document — right-click a document in the tree to add a child under it"
                    }
                    background: Rectangle {
                        radius: height / 2
                        color: parent.down ? "#c7c7c7"
                             : parent.hovered ? "#dddddd" : "#d6d6d6"
                    }
                }

                // Documents / Templates switch: swaps which tree is shown and
                // which one Add and the editor act on
                TabBar {
                    id: viewTabs
                    Layout.fillWidth: true
                    Layout.leftMargin: 8
                    Layout.rightMargin: 8
                    Layout.bottomMargin: 6
                    enabled: !win.editing
                    currentIndex: win.templateMode ? 1 : 0
                    onCurrentIndexChanged: win.templateMode = (currentIndex === 1)
                    background: null

                    TabButton {
                        text: "Documents"
                        font.capitalization: Font.MixedCase
                        font.pixelSize: 13
                    }
                    TabButton {
                        text: "Templates"
                        font.capitalization: Font.MixedCase
                        font.pixelSize: 13
                        HoverTip { text: "Instructions the AI agent follows when it creates or edits documents" }
                    }
                }

                MenuSeparator { Layout.fillWidth: true; padding: 0 }

                Item {
                    Layout.fillWidth: true
                    Layout.fillHeight: true

                    TreeView {
                        id: tree
                        anchors.fill: parent
                        clip: true
                        model: win.templateMode ? templateModel : docModel
                        // all expand/collapse goes through our animated handlers below;
                        // this kills the built-in instant double-tap toggle
                        pointerNavigationEnabled: false

                        // the model resets wholesale on every change, which collapses
                        // the tree — remember expanded docs and restore them
                        property var expandedIds: ({})
                        onExpanded: function (row, depth) {
                            expandedIds[docModel.docIdFor(tree.index(row, 0))] = true
                        }
                        onCollapsed: function (row, recursively) {
                            delete expandedIds[docModel.docIdFor(tree.index(row, 0))]
                        }
                        Connections {
                            // follows the active tree; the other model resetting
                            // (both reload on store.changed) mustn't disturb the
                            // rows on screen
                            target: tree.model
                            function onModelReset() {
                                for (var id in tree.expandedIds) {
                                    var idx = tree.model.indexForDoc(parseInt(id))
                                    if (!idx.valid)
                                        continue
                                    tree.expandToIndex(idx) // ancestors
                                    tree.expand(tree.rowAtIndex(idx)) // the node itself
                                }
                            }
                        }

                        function delegateAt(r) {
                            var idx = tree.index(r, 0)
                            var it = tree.itemAtIndex ? tree.itemAtIndex(idx) : null
                            if (!it && tree.itemAtCell)
                                it = tree.itemAtCell(Qt.point(0, r))
                            return it
                        }

                        // fade/shrink a subtree's rows before actually collapsing them
                        function collapseWithFade(row) {
                            if (collapseAnim.running)
                                return
                            var d = tree.depth(row)
                            var items = []
                            for (var r = row + 1; r < tree.rows && tree.depth(r) > d; ++r) {
                                var it = delegateAt(r)
                                if (it)
                                    items.push(it)
                            }
                            if (items.length === 0) { // nothing visible to animate
                                tree.collapse(row)
                                return
                            }
                            collapseAnim.row = row
                            collapseAnim.items = items
                            collapseAnim.restart()
                        }
                        ParallelAnimation {
                            id: collapseAnim
                            property int row: -1
                            property var items: []
                            NumberAnimation {
                                targets: collapseAnim.items
                                property: "opacity"
                                to: 0
                                duration: 140
                                easing.type: Easing.OutCubic
                            }
                            NumberAnimation {
                                targets: collapseAnim.items
                                property: "scale"
                                to: 0.85
                                duration: 140
                                easing.type: Easing.OutCubic
                            }
                            // pooled rows restore opacity/scale via appearAnim on reuse
                            onFinished: tree.collapse(row)
                        }
                        delegate: TreeViewDelegate {
                            id: treeRow
                            implicitWidth: tree.width
                            // extra breathing room between top-level documents
                            implicitHeight: treeRow.depth === 0 ? 48 : 38
                            // the style's uneven vertical padding pushed the icon+label
                            // band below the row center the indicator is centered on
                            topPadding: 0
                            bottomPadding: 0
                            highlighted: model.docId === win.currentDocId
                            // clicking a row opens it and, for parents, toggles the
                            // subtree — the one input path TableView can't intercept
                            onClicked: {
                                win.openDoc(model.docId)
                                if (treeRow.hasChildren) {
                                    if (treeRow.expanded)
                                        tree.collapseWithFade(treeRow.row)
                                    else
                                        tree.expand(treeRow.row)
                                }
                            }

                            TapHandler {
                                acceptedButtons: Qt.RightButton
                                onTapped: {
                                    if (!win.editing)
                                        win.currentDocId = treeRow.model.docId
                                    rowMenu.popup()
                                }
                            }
                            Menu {
                                id: rowMenu
                                MenuItem {
                                    text: win.templateMode ? "Add template" : "Add document"
                                    enabled: !win.editing
                                    onTriggered: win.startNew(treeRow.model.docId)
                                }
                                MenuItem {
                                    text: "Edit"
                                    enabled: !win.editing
                                    onTriggered: win.startEdit(treeRow.model.docId)
                                }
                                MenuSeparator {}
                                MenuItem {
                                    text: win.templateMode ? "Move to Documents" : "Move to Templates"
                                    enabled: !win.editing
                                    onTriggered: store.setDocumentTemplate(
                                        treeRow.model.docId, !win.templateMode)
                                }
                            }

                            // rows slide down and fade in when revealed by expanding their parent
                            transform: Translate { id: slide }
                            Component.onCompleted: appearAnim.restart()
                            TableView.onReused: appearAnim.restart()
                            ParallelAnimation {
                                id: appearAnim
                                NumberAnimation {
                                    target: treeRow
                                    property: "opacity"
                                    from: 0; to: 1
                                    duration: 200
                                    easing.type: Easing.OutCubic
                                }
                                NumberAnimation {
                                    target: slide
                                    property: "y"
                                    from: -treeRow.height / 2; to: 0
                                    duration: 200
                                    easing.type: Easing.OutCubic
                                }
                            }

                            background: Rectangle {
                                anchors.fill: parent
                                anchors.leftMargin: 4
                                anchors.rightMargin: 4
                                radius: 4
                                color: treeRow.highlighted ? "#e8eaf6"
                                     : treeRow.hovered ? "#eeeeee" : "transparent"
                            }

                            // custom indicator with animated rotation; presses on the
                            // arrow are handled here — the delegate swallows them
                            // otherwise (it suppresses clicked() for indicator presses
                            // and routes to the view toggle we disabled)
                            indicator: Item {
                                x: treeRow.leftMargin + (treeRow.depth * treeRow.indentation)
                                y: (treeRow.height - height) / 2
                                width: 20
                                height: 20
                                implicitWidth: 20
                                implicitHeight: 20
                                visible: treeRow.hasChildren
                                // drawn triangle instead of a "▶" glyph: font
                                // baseline metrics kept the arrow optically high
                                // next to the icon and label
                                Canvas {
                                    anchors.fill: parent
                                    // raster target so the arrow paints on the
                                    // software backend (no GL), not just on GPU
                                    renderTarget: Canvas.Image
                                    renderStrategy: Canvas.Immediate
                                    rotation: treeRow.expanded ? 90 : 0
                                    Behavior on rotation {
                                        NumberAnimation { duration: 150; easing.type: Easing.OutCubic }
                                    }
                                    onPaint: {
                                        var ctx = getContext("2d")
                                        ctx.clearRect(0, 0, width, height)
                                        ctx.fillStyle = "#78909c"
                                        ctx.beginPath()
                                        ctx.moveTo(width * 0.38, height * 0.27)
                                        ctx.lineTo(width * 0.38, height * 0.73)
                                        ctx.lineTo(width * 0.74, height * 0.5)
                                        ctx.closePath()
                                        ctx.fill()
                                    }
                                }
                                MouseArea {
                                    anchors.fill: parent
                                    preventStealing: true
                                    onClicked: treeRow.expanded ? tree.collapseWithFade(treeRow.row)
                                                                : tree.expand(treeRow.row)
                                }
                            }

                            // IDE-style row: folder/file icon + name, indentation only
                            contentItem: Row {
                                spacing: 8

                                DocumentGlyph {
                                    anchors.verticalCenter: parent.verticalCenter
                                    folder: treeRow.hasChildren
                                    open: treeRow.expanded
                                }

                                Label {
                                    anchors.verticalCenter: parent.verticalCenter
                                    width: Math.max(0, treeRow.width - x - 12)
                                    text: treeRow.model.display
                                    elide: Text.ElideRight
                                    font.weight: treeRow.depth === 0 ? Font.Bold
                                               : treeRow.hasChildren ? Font.DemiBold : Font.Normal
                                    color: "#37474f"
                                }
                            }
                        }
                    }

                }
            }
        }

        // Editor: title + rich text controls span the full width, above the document.
        Rectangle {
            id: editorPane
            visible: win.editing
            SplitView.fillWidth: true
            SplitView.minimumWidth: 400
            color: Material.background

            ColumnLayout {
                anchors.fill: parent
                anchors.margins: 12
                spacing: 8

                RowLayout {
                    Layout.fillWidth: true
                    spacing: 12
                    TextField {
                        id: titleField
                        Layout.fillWidth: true
                        placeholderText: "Title"
                        font.pixelSize: 18
                    }
                    Switch {
                        id: previewSwitch
                        text: "Preview"
                        checked: true
                    }
                    Button {
                        text: "Save"
                        font.capitalization: Font.MixedCase
                        highlighted: true
                        enabled: titleField.text.trim() !== ""
                        onClicked: win.saveDoc()
                    }
                    Button {
                        text: "Close"
                        font.capitalization: Font.MixedCase
                        flat: true
                        onClicked: win.closeEditor()
                    }
                }

                Flow {
                    Layout.fillWidth: true
                    spacing: 2
                    FmtButton { text: "B"; font.bold: true; onClicked: win.wrapSel("**", "**"); tip: "Bold" }
                    FmtButton { text: "I"; font.italic: true; onClicked: win.wrapSel("*", "*"); tip: "Italic" }
                    FmtButton { text: "S"; font.strikeout: true; onClicked: win.wrapSel("~~", "~~"); tip: "Strikethrough" }
                    ToolSeparator { implicitHeight: 40 }
                    FmtButton { text: "H1"; onClicked: win.linePrefix("# "); tip: "Heading 1" }
                    FmtButton { text: "H2"; onClicked: win.linePrefix("## "); tip: "Heading 2" }
                    FmtButton { text: "H3"; onClicked: win.linePrefix("### "); tip: "Heading 3" }
                    ToolSeparator { implicitHeight: 40 }
                    FmtButton { text: "‹›"; onClicked: win.wrapSel("`", "`"); tip: "Inline code" }
                    FmtButton { text: "{ }"; onClicked: win.wrapSel("\n```\n", "\n```\n"); tip: "Code block" }
                    ToolSeparator { implicitHeight: 40 }
                    FmtButton { text: "•"; onClicked: win.linePrefix("- "); tip: "Bullet list" }
                    FmtButton { text: "1."; onClicked: win.linePrefix("1. "); tip: "Numbered list" }
                    FmtButton { text: "❝"; onClicked: win.linePrefix("> "); tip: "Quote" }
                    FmtButton { text: "🔗"; onClicked: win.wrapSel("[", "](url)"); tip: "Link" }
                }

                SplitView {
                    id: editorSplit
                    Layout.fillWidth: true
                    Layout.fillHeight: true

                    Rectangle {
                        SplitView.preferredWidth: previewSwitch.checked ? editorSplit.width * 0.5
                                                                        : editorSplit.width
                        SplitView.minimumWidth: 200
                        radius: 8
                        color: "white"
                        border.width: 1
                        border.color: win.borderColor
                        clip: true

                        ScrollView {
                            anchors.fill: parent
                            anchors.margins: 6
                            TextArea {
                                id: editor
                                wrapMode: TextArea.Wrap
                                font.family: "monospace"
                                background: null // the card provides the border
                                // keep the selection when a toolbar button takes
                                // the click — wrapSel() wraps whatever is selected
                                persistentSelection: true
                                placeholderText: "Write in Markdown — toggle Preview to see it rendered."
                            }
                        }
                    }

                    Rectangle {
                        visible: previewSwitch.checked
                        SplitView.fillWidth: true
                        SplitView.minimumWidth: 200
                        radius: 8
                        color: "white"
                        border.width: 1
                        border.color: win.borderColor
                        clip: true

                        ColumnLayout {
                            anchors.fill: parent
                            anchors.margins: 1
                            spacing: 0

                            Rectangle {
                                Layout.fillWidth: true
                                implicitHeight: 36
                                radius: 7
                                color: "#e8eaf6"
                                Label {
                                    text: "Preview"
                                    anchors.left: parent.left
                                    anchors.leftMargin: 12
                                    anchors.verticalCenter: parent.verticalCenter
                                    font.weight: Font.Medium
                                    color: "#3949ab"
                                }
                            }

                            Flickable {
                                Layout.fillWidth: true
                                Layout.fillHeight: true
                                contentHeight: previewView.contentHeight + 24
                                clip: true
                                ScrollBar.vertical: ScrollBar {}

                                TextEdit {
                                    id: previewView
                                    width: parent.width
                                    padding: 16
                                    readOnly: true
                                    wrapMode: TextEdit.Wrap
                                    // ponytail: crude content-type sniff — leading '<' means raw HTML, else Markdown
                                    textFormat: editor.text.trim().startsWith("<") ? TextEdit.RichText
                                                                                   : TextEdit.MarkdownText
                                    text: editor.text
                                    font.pixelSize: 15
                                    color: "#212121"
                                }
                            }
                        }
                    }
                }
            }
        }

        Item {
            visible: !win.editing
            SplitView.fillWidth: true
            SplitView.minimumWidth: 200

            Flickable {
                id: flick
                anchors.fill: parent
                contentWidth: width
                contentHeight: docView.height + 48
                clip: true
                ScrollBar.vertical: ScrollBar {}
                // no Behavior on contentHeight: it restarts every stream frame
                // and rubber-bands; the eased char pacing already reads smooth

                TextEdit {
                    id: docView
                    x: 32
                    y: 24
                    width: flick.width - 64
                    readOnly: true
                    selectByMouse: true
                    persistentSelection: true // keep selection while the clarify popup has focus
                    wrapMode: TextEdit.Wrap
                    // native raster glyphs: the default distance-field atlas drops
                    // runs of a tall TextEdit when scrolled off and back into view
                    // (blank gaps), especially on software/no-GPU backends
                    renderType: Text.NativeRendering
                    // Ctrl+C copies Markdown source, not rendered text, so pasting
                    // into another document keeps the formatting intact
                    Keys.onPressed: function (e) {
                        if ((e.modifiers & Qt.ControlModifier) && e.key === Qt.Key_C
                                && selectedText.length > 0) {
                            highlighter.copyAsMarkdown(textDocument, selectionStart,
                                                       selectionEnd, win.docContent)
                            e.accepted = true
                        }
                    }
                    // ponytail: crude content-type sniff — leading '<' means raw HTML, else Markdown
                    textFormat: win.docContent.trim().startsWith("<") ? TextEdit.RichText
                                                                      : TextEdit.MarkdownText
                    text: win.currentDocId >= 0 ? win.docContent
                                                : "*Select a document from the tree.*"
                    font.pixelSize: 15
                    color: "#212121"
                    onLinkActivated: function (link) { Qt.openUrlExternally(link) }

                    // documents fade in softly when opened
                    ParallelAnimation {
                        id: docAppear
                        NumberAnimation {
                            target: docView
                            property: "opacity"
                            from: 0; to: 1
                            duration: 220
                            easing.type: Easing.OutCubic
                        }
                    }

                    // a soft glow trails the streaming frontier, like a cursor
                    Rectangle {
                        id: streamGlow
                        visible: win.streaming
                        property rect tip: {
                            docView.text
                            return docView.posRect(docView.length - 1)
                        }
                        x: Math.max(0, tip.x - width)
                        y: tip.y
                        width: 80
                        height: tip.height
                        radius: height / 2
                        gradient: Gradient {
                            orientation: Gradient.Horizontal
                            GradientStop { position: 0.0; color: "transparent" }
                            GradientStop { position: 1.0; color: Qt.alpha(win.animAccent, 0.45) }
                        }
                        SequentialAnimation on opacity {
                            running: win.streaming
                            loops: Animation.Infinite
                            NumberAnimation { from: 0.5; to: 1.0; duration: 550; easing.type: Easing.InOutSine }
                            NumberAnimation { from: 1.0; to: 0.5; duration: 550; easing.type: Easing.InOutSine }
                        }
                    }

                    // positionToRectangle with the position clamped into the
                    // current document — overlay bindings re-evaluate mid-stream
                    // with ranges from the previous highlight pass
                    function posRect(p) {
                        return positionToRectangle(Math.max(0, Math.min(p, length - 1)))
                    }

                    // which clarification highlight the mouse is inside, or -1
                    property int hoverRange: -1

                    function rangeAt(px, py) {
                        var pos = positionAt(px, py)
                        for (var i = 0; i < win.clarifyRanges.length; ++i) {
                            var r = win.clarifyRanges[i]
                            if (r.start >= 0 && pos >= r.start && pos < r.end)
                                return i
                        }
                        return -1
                    }

                    function setHoverRange(i) {
                        if (win.streaming)
                            return // ranges are in flux; repainting them would use stale positions
                        if (i === hoverRange)
                            return
                        if (hoverRange >= 0) {
                            var o = win.clarifyRanges[hoverRange]
                            highlighter.hover(textDocument, o.start, o.end, false)
                        }
                        if (i >= 0) {
                            var r = win.clarifyRanges[i]
                            highlighter.hover(textDocument, r.start, r.end, true)
                        }
                        hoverRange = i
                    }

                    HoverHandler {
                        cursorShape: docView.hoveredLink !== "" || docView.hoverRange >= 0
                                     ? Qt.PointingHandCursor : Qt.IBeamCursor
                        onPointChanged: docView.setHoverRange(
                                            docView.rangeAt(point.position.x, point.position.y))
                        onHoveredChanged: if (!hovered) docView.setHoverRange(-1)
                    }

                    // click a gold highlight to view/delete its clarification
                    TapHandler {
                        acceptedButtons: Qt.LeftButton
                        onTapped: function (eventPoint) {
                            var i = docView.rangeAt(eventPoint.position.x, eventPoint.position.y)
                            if (i < 0)
                                return
                            var r = win.clarifyRanges[i]
                            clarifyView.clarif = r
                            var rect = docView.positionToRectangle(r.start)
                            clarifyView.x = Math.max(0, Math.min(rect.x, docView.width - clarifyView.width))
                            clarifyView.y = rect.y + 24
                            clarifyView.open()
                        }
                    }
                    TapHandler {
                        acceptedButtons: Qt.RightButton
                        onTapped: docMenu.popup()
                    }
                    Menu {
                        id: docMenu
                        MenuItem {
                            text: "Copy (keep formatting)"
                            enabled: docView.selectedText.length > 0
                            onTriggered: highlighter.copyAsMarkdown(
                                docView.textDocument, docView.selectionStart,
                                docView.selectionEnd, win.docContent)
                        }
                        MenuItem {
                            text: "Select all"
                            enabled: win.currentDocId > 0
                            onTriggered: docView.selectAll()
                        }
                        MenuSeparator {}
                        MenuItem {
                            text: "Edit"
                            enabled: win.currentDocId > 0 && !win.editing
                            onTriggered: win.startEdit(win.currentDocId)
                        }
                    }

                    // while revising: a light band sweeps across each quoted
                    // passage under revision (same rhythm as the button);
                    // one sheen per wrapped line, covering only the text
                    Repeater {
                        model: {
                            if (!win.revising)
                                return []
                            docView.text; docView.width // re-eval on relayout
                            var out = []
                            for (var i = 0; i < win.clarifyRanges.length; ++i) {
                                var r = win.clarifyRanges[i]
                                if (r.start >= 0)
                                    out = out.concat(highlighter.lineRects(
                                        docView.textDocument, r.start, r.end))
                            }
                            return out
                        }
                        delegate: Sheen {
                            required property var modelData
                            x: modelData.x
                            y: modelData.y
                            width: modelData.width
                            height: modelData.height
                        }
                    }

                    // dark slabs behind code-block runs; z < 0 paints under the text
                    Repeater {
                        model: win.codeRanges
                        delegate: Rectangle {
                            id: codeSlab
                            required property var modelData
                            z: -1
                            radius: 6
                            color: "#263238"
                            x: -12
                            width: docView.width + 24
                            // touch width/text so geometry re-resolves on relayout.
                            // 32px header strip above the code (holds the copy
                            // button) and 18px pad below; both sit inside the code
                            // block margins so a ~12-14px gap stays around the slab
                            y: { docView.width; docView.text; return docView.posRect(codeSlab.modelData.start).y - 32 }
                            height: {
                                docView.width
                                docView.text
                                var r = docView.posRect(codeSlab.modelData.end)
                                return r.y + r.height - y + 18
                            }
                        }
                    }

                    // per-code-block copy buttons, right-aligned in the slab's header
                    // strip above the code so they never sit on the code text
                    Repeater {
                        model: win.codeRanges
                        delegate: ToolButton {
                            id: copyBtn
                            required property var modelData
                            property bool copied: false
                            text: copied ? "Copied!" : "Copy"
                            font.pixelSize: 11
                            font.capitalization: Font.MixedCase
                            implicitHeight: 24
                            // touch width/text so the position re-resolves on relayout
                            x: { docView.width; return docView.width - width - 4 }
                            y: { docView.width; docView.text; return docView.posRect(copyBtn.modelData.start).y - 30 }
                            onClicked: {
                                highlighter.copy(copyBtn.modelData.text)
                                copied = true
                                copiedReset.restart()
                            }
                            Timer { id: copiedReset; interval: 1200; onTriggered: copyBtn.copied = false }
                            Material.foreground: "#eceff1"
                            background: Rectangle {
                                radius: 4
                                color: copyBtn.down ? "#607d8b" : copyBtn.hovered ? "#546e7a" : "#455a64"
                            }
                        }
                    }

                    // floating affordance next to a text selection
                    RoundButton {
                        id: clarifyBtn
                        text: "Request clarification…"
                        font.capitalization: Font.MixedCase
                        font.pixelSize: 12
                        visible: win.currentDocId > 0 && docView.selectedText.length > 0
                                 && !clarifyPop.visible
                        x: Math.min(docView.positionToRectangle(docView.selectionEnd).x,
                                    docView.width - width)
                        y: docView.positionToRectangle(docView.selectionEnd).y + 24
                        background: Rectangle {
                            radius: height / 2
                            color: clarifyBtn.down ? "#ffe082"
                                 : clarifyBtn.hovered ? win.clarifyBgHover : win.clarifyBg
                            border.width: 1
                            border.color: win.clarifyBorder
                        }
                        onClicked: {
                            clarifyPop.quote = docView.selectedText
                            clarifyPop.x = Math.min(x, docView.width - clarifyPop.width)
                            clarifyPop.y = y
                            clarifyPop.open()
                        }
                    }

                    Popup {
                        id: clarifyPop
                        property string quote: ""
                        padding: 10
                        background: Rectangle {
                            radius: 8
                            color: win.clarifyBg
                            border.width: 1
                            border.color: win.clarifyBorder
                        }
                        onOpened: clarifyText.forceActiveFocus()

                        ColumnLayout {
                            spacing: 8
                            TextArea {
                                id: clarifyText
                                Layout.preferredWidth: 280
                                placeholderText: "What should be clarified here?"
                                wrapMode: TextArea.Wrap
                            }
                            Button {
                                text: "Request Clarification"
                                font.capitalization: Font.MixedCase
                                highlighted: true
                                enabled: clarifyText.text.trim() !== ""
                                onClicked: {
                                    store.addClarification(win.currentDocId, clarifyPop.quote,
                                                           clarifyText.text.trim())
                                    clarifyText.text = ""
                                    clarifyPop.close()
                                }
                            }
                        }
                    }

                    // shows one clarification when its highlight is clicked
                    Popup {
                        id: clarifyView
                        property var clarif: ({})
                        padding: 12
                        background: Rectangle {
                            radius: 8
                            color: win.clarifyBg
                            border.width: 1
                            border.color: win.clarifyBorder
                        }

                        ColumnLayout {
                            spacing: 6
                            Label {
                                Layout.preferredWidth: 280
                                text: clarifyView.clarif.comment || ""
                                wrapMode: Text.Wrap
                                font.pixelSize: 13
                            }
                            RowLayout {
                                Layout.fillWidth: true
                                Label {
                                    Layout.fillWidth: true
                                    text: "“" + (clarifyView.clarif.quoted_text || "") + "”"
                                    elide: Text.ElideRight
                                    font.italic: true
                                    font.pixelSize: 12
                                    opacity: 0.6
                                }
                                Button {
                                    text: "Delete"
                                    flat: true
                                    font.capitalization: Font.MixedCase
                                    Material.foreground: "#c62828"
                                    onClicked: {
                                        store.resolveClarification(clarifyView.clarif.id)
                                        clarifyView.close()
                                    }
                                }
                            }
                        }
                    }
                }
            }

            // fade-through cover for document updates: dim to the page colour,
            // swap the text while it's hidden, then reveal — the change flows in
            // with no reflow jump and no double image (see streamTo / applyPending).
            // Declared after the Flickable but before the buttons so it covers only
            // the document, leaving the Revise/clarification controls on top.
            Rectangle {
                id: docCover
                anchors.fill: flick
                color: win.Material.background
                opacity: 0
                visible: opacity > 0.001
            }
            SequentialAnimation {
                id: docFade
                NumberAnimation {
                    target: docCover; property: "opacity"
                    from: 0; to: 1; duration: 120; easing.type: Easing.InQuad
                }
                ScriptAction { script: win.applyPending() }
                NumberAnimation {
                    target: docCover; property: "opacity"
                    from: 1; to: 0; duration: 240; easing.type: Easing.OutQuad
                }
            }

            // blue Revise: send all clarification requests to the AI provider
            RoundButton {
                id: reviseBtn
                anchors.top: parent.top
                anchors.right: clarifListBtn.left
                anchors.margins: 12
                anchors.rightMargin: 8
                visible: win.currentDocId > 0 && win.clarifs.length > 0
                enabled: !win.revising && win.clarifs.length > 0
                opacity: enabled ? 1 : 0.6
                text: win.revising ? "Revising…" : "✦ Revise"
                font.pixelSize: 13
                font.capitalization: Font.MixedCase
                Material.foreground: "white"
                // subtle breathing while a revision is in flight
                SequentialAnimation on scale {
                    running: win.revising
                    loops: Animation.Infinite
                    NumberAnimation { from: 1.0; to: 1.05; duration: 550; easing.type: Easing.InOutSine }
                    NumberAnimation { from: 1.05; to: 1.0; duration: 550; easing.type: Easing.InOutSine }
                    onStopped: reviseBtn.scale = 1.0
                }
                background: Rectangle {
                    radius: height / 2
                    property color base: !reviseBtn.enabled && !win.revising ? "#90caf9"
                                       : reviseBtn.down ? "#1565c0"
                                       : reviseBtn.hovered ? "#1976d2" : "#1e88e5"
                    // while revising, a lighter band flows across the pill —
                    // same 1100ms rhythm as the Sheen on the quoted text
                    gradient: Gradient {
                        orientation: Gradient.Horizontal
                        GradientStop { position: 0.0; color: reviseBtn.background.base }
                        GradientStop {
                            id: reviseBand
                            position: 0.5
                            color: win.revising ? win.animAccent : reviseBtn.background.base
                            SequentialAnimation on position {
                                running: win.revising
                                loops: Animation.Infinite
                                NumberAnimation { from: 0.1; to: 0.9; duration: 550; easing.type: Easing.InOutSine }
                                NumberAnimation { from: 0.9; to: 0.1; duration: 550; easing.type: Easing.InOutSine }
                                onStopped: reviseBand.position = 0.5
                            }
                        }
                        GradientStop { position: 1.0; color: reviseBtn.background.base }
                    }
                }
                HoverTip {
                    text: win.clarifs.length === 0
                          ? "No clarification requests to revise"
                          : "Have the AI provider revise the document to address all clarification requests"
                }
                onClicked: {
                    if (!reviser.ready()) {
                        aiDialog.open()
                        return
                    }
                    win.reviseError = ""
                    reviser.revise(win.currentDocId)
                }
            }

            // non-blocking error readout under the Revise button
            Label {
                anchors.top: reviseBtn.bottom
                anchors.right: parent.right
                anchors.margins: 12
                anchors.topMargin: 4
                visible: win.reviseError !== ""
                text: win.reviseError
                color: "#c62828"
                font.pixelSize: 12
                Timer {
                    running: win.reviseError !== ""
                    interval: 8000
                    onTriggered: win.reviseError = ""
                }
            }

            Connections {
                target: reviser

                function onStarted(docId) {
                    win.revising = true
                }
                function onFinished(docId) {
                    win.revising = false
                    // store.changed already refreshed the reader with the new text
                }
                function onError(message) {
                    win.revising = false
                    win.reviseError = message
                }
            }

            // top-right: all clarification requests on this document
            RoundButton {
                id: clarifListBtn
                anchors.top: parent.top
                anchors.right: parent.right
                anchors.margins: 12
                visible: win.currentDocId > 0 && win.clarifs.length > 0
                text: "⚑ " + win.clarifs.length
                font.pixelSize: 13
                background: Rectangle {
                    radius: height / 2
                    color: clarifListBtn.down ? "#ffe082"
                         : clarifListBtn.hovered ? win.clarifyBgHover : win.clarifyBg
                    border.width: 1
                    border.color: win.clarifyBorder
                }
                onClicked: clarifListPop.open()
                HoverTip { text: "Clarification requests" }
            }

            Popup {
                id: clarifListPop
                x: parent.width - width - 12
                y: clarifListBtn.y + clarifListBtn.height + 8
                width: 360
                height: Math.min(400, clarifList.contentHeight + topPadding + bottomPadding)
                padding: 6
                background: Rectangle {
                    radius: 8
                    color: "white"
                    border.width: 1
                    border.color: win.clarifyBorder
                }

                contentItem: ListView {
                    id: clarifList
                    clip: true
                    model: win.clarifs
                    ScrollBar.vertical: ScrollBar {}
                    delegate: ItemDelegate {
                        id: clarifEntry
                        required property var modelData
                        width: clarifList.width
                        // click an entry to jump to its quote in the document
                        onClicked: {
                            win.locateQuote(clarifEntry.modelData.quoted_text)
                            clarifListPop.close()
                        }
                        background: Rectangle {
                            radius: 6
                            color: clarifEntry.down ? "#ffe082"
                                 : clarifEntry.hovered ? win.clarifyBgHover : "transparent"
                        }
                        contentItem: RowLayout {
                            spacing: 6
                            ColumnLayout {
                                Layout.fillWidth: true
                                spacing: 2
                                Label {
                                    Layout.fillWidth: true
                                    text: clarifEntry.modelData.comment
                                    wrapMode: Text.Wrap
                                    font.pixelSize: 13
                                }
                                Label {
                                    Layout.fillWidth: true
                                    text: "“" + clarifEntry.modelData.quoted_text + "”"
                                    elide: Text.ElideRight
                                    font.italic: true
                                    font.pixelSize: 12
                                    opacity: 0.6
                                }
                            }
                            ToolButton {
                                text: "✕"
                                implicitWidth: 32
                                implicitHeight: 32
                                onClicked: {
                                    store.resolveClarification(clarifEntry.modelData.id)
                                    if (win.clarifs.length === 0)
                                        clarifListPop.close()
                                }
                                HoverTip { text: "Delete request" }
                            }
                        }
                    }
                }
            }
        }

        // Right-side assistant: a conversational Claude Code session with full
        // access to the Recall MCP tools, so the agent reads and edits the wiki
        // live as you chat. Edits land in the shared db and stream into the
        // reader like any other external change.
        Rectangle {
            id: chatPane
            visible: win.chatOpen
            SplitView.preferredWidth: 380
            SplitView.minimumWidth: 300
            color: "#f5f6fa"

            ColumnLayout {
                anchors.fill: parent
                spacing: 0

                Rectangle {
                    Layout.fillWidth: true
                    implicitHeight: 48
                    color: "#e8eaf6"
                    RowLayout {
                        anchors.fill: parent
                        anchors.leftMargin: 14
                        anchors.rightMargin: 6
                        spacing: 4
                        Label {
                            text: "Assistant"
                            font.pixelSize: 16
                            font.weight: Font.Medium
                            color: "#3949ab"
                            Layout.fillWidth: true
                        }
                        ToolButton {
                            id: activityToggle
                            text: "Activity"
                            font.capitalization: Font.MixedCase
                            font.pixelSize: 12
                            Material.foreground: win.activityExpanded ? "#3949ab" : "#90a4ae"
                            onClicked: win.activityPinned = !win.activityPinned
                            HoverTip { text: win.activityExpanded ? "Hide the activity log"
                                                                  : "Show the activity log" }
                        }
                        ToolButton {
                            text: "New chat"
                            font.capitalization: Font.MixedCase
                            font.pixelSize: 12
                            enabled: !win.chatBusy && chatModel.count > 0
                            onClicked: { chat.reset(); chatModel.clear(); techModel.clear(); win.chatRefs = [] }
                            HoverTip { text: "Start a new conversation (clears context)" }
                        }
                        ToolButton {
                            text: "✕"
                            implicitWidth: 36
                            implicitHeight: 36
                            onClicked: win.chatOpen = false
                            HoverTip { text: "Hide assistant" }
                        }
                    }
                }

                ListView {
                    id: chatList
                    Layout.fillWidth: true
                    Layout.fillHeight: true
                    clip: true
                    model: chatModel
                    spacing: 12
                    topMargin: 12
                    bottomMargin: 12
                    leftMargin: 12
                    rightMargin: 12
                    ScrollBar.vertical: ScrollBar {}

                    Label {
                        anchors.centerIn: parent
                        width: parent.width - 48
                        visible: chatModel.count === 0
                        horizontalAlignment: Text.AlignHCenter
                        wrapMode: Text.Wrap
                        opacity: 0.6
                        font.pixelSize: 13
                        text: (chat && chat.available())
                              ? "Ask me to add or update documentation, or to look something up — I edit the wiki live as we talk. Type @ to reference a document."
                              : "Chat needs the Claude Code CLI. Install it and log in, then reopen this panel."
                    }

                    delegate: Column {
                        id: msg
                        required property var model
                        width: chatList.width - chatList.leftMargin - chatList.rightMargin
                        spacing: 4
                        readonly property string kind: model.kind
                        readonly property bool isUser: kind === "user"
                        readonly property bool isAssistant: kind === "assistant"
                        readonly property bool bubble: isUser || isAssistant

                        // user message: indigo bubble, right-aligned, selectable
                        Row {
                            visible: msg.isUser
                            width: msg.width
                            layoutDirection: Qt.RightToLeft
                            Rectangle {
                                width: Math.min(uedit.implicitWidth + 24, msg.width * 0.85)
                                height: uedit.contentHeight + 18
                                radius: 12
                                color: "#5c6bc0"
                                TextEdit {
                                    id: uedit
                                    x: 12
                                    y: 9
                                    width: parent.width - 24
                                    readOnly: true
                                    selectByMouse: true
                                    persistentSelection: true
                                    wrapMode: TextEdit.Wrap
                                    textFormat: TextEdit.PlainText
                                    text: msg.model.text
                                    font.pixelSize: 13
                                    color: "white"
                                }
                            }
                        }

                        // assistant reply: white bubble, left-aligned, Markdown,
                        // selectable, with add-to-document / copy actions beneath
                        Column {
                            visible: msg.isAssistant
                            width: msg.width
                            spacing: 3

                            Rectangle {
                                width: Math.min(aedit.implicitWidth + 24, msg.width * 0.95)
                                height: aedit.contentHeight + 18
                                radius: 12
                                color: "white"
                                border.width: 1
                                border.color: win.borderColor
                                TextEdit {
                                    id: aedit
                                    x: 12
                                    y: 9
                                    width: parent.width - 24
                                    readOnly: true
                                    selectByMouse: true
                                    persistentSelection: true
                                    wrapMode: TextEdit.Wrap
                                    textFormat: TextEdit.MarkdownText
                                    text: msg.model.text
                                    font.pixelSize: 13
                                    color: "#212121"
                                    onLinkActivated: function (link) { Qt.openUrlExternally(link) }
                                }
                            }

                            Row {
                                leftPadding: 4
                                spacing: 10
                                ChatLink {
                                    height: 26
                                    verticalAlignment: Text.AlignVCenter
                                    text: aedit.selectedText.length > 0 ? "+ Add selection to document"
                                                                        : "+ Add to document"
                                    active: win.currentDocId > 0 && !win.editing
                                    onClicked: {
                                        var t = aedit.selectedText.length > 0 ? aedit.selectedText
                                                                              : msg.model.text
                                        if (win.addToCurrentDoc(t))
                                            aedit.deselect()
                                    }
                                }
                                CopyIconButton {
                                    payload: aedit.selectedText.length > 0 ? aedit.selectedText
                                                                           : msg.model.text
                                }
                            }
                        }

                        // tool activity / notices / errors: subtle full-width lines
                        Label {
                            visible: !msg.bubble
                            width: msg.width
                            text: msg.model.text
                            wrapMode: Text.Wrap
                            font.family: msg.kind === "tool" ? "monospace" : win.font.family
                            font.pixelSize: msg.kind === "error" ? 12 : 11
                            color: (msg.kind === "error" || msg.kind === "note") ? "#c62828" : "#607d8b"
                        }
                    }
                }

                // "working" pulse while a turn is in flight
                Label {
                    Layout.fillWidth: true
                    Layout.leftMargin: 16
                    Layout.topMargin: 2
                    Layout.bottomMargin: 2
                    visible: win.chatBusy
                    text: "✦ Working…"
                    font.pixelSize: 12
                    color: "#3949ab"
                    SequentialAnimation on opacity {
                        running: win.chatBusy
                        loops: Animation.Infinite
                        NumberAnimation { from: 0.4; to: 1.0; duration: 600; easing.type: Easing.InOutSine }
                        NumberAnimation { from: 1.0; to: 0.4; duration: 600; easing.type: Easing.InOutSine }
                    }
                }

                Rectangle {
                    Layout.fillWidth: true
                    Layout.margins: 8
                    implicitHeight: inputRow.implicitHeight + 12
                    radius: 8
                    color: "white"
                    border.width: 1
                    border.color: chatInput.activeFocus ? win.Material.accent : win.borderColor

                    RowLayout {
                        id: inputRow
                        anchors.fill: parent
                        anchors.leftMargin: 8
                        anchors.rightMargin: 6
                        anchors.topMargin: 4
                        anchors.bottomMargin: 4
                        spacing: 6

                        // ScrollView caps the height and scrolls internally with the
                        // scrollbar hidden, so long input scrolls instead of spilling
                        // out of the field
                        ScrollView {
                            id: chatInputScroll
                            Layout.fillWidth: true
                            Layout.maximumHeight: 120
                            Layout.alignment: Qt.AlignVCenter
                            clip: true
                            ScrollBar.vertical.policy: ScrollBar.AlwaysOff
                            ScrollBar.horizontal.policy: ScrollBar.AlwaysOff

                            TextArea {
                                id: chatInput
                                width: chatInputScroll.availableWidth
                                enabled: (chat && chat.available()) && !win.chatBusy
                                wrapMode: TextArea.Wrap
                                background: null
                                font.pixelSize: 13
                                placeholderText: (chat && chat.available()) ? "Ask the assistant…  (@ to reference a document · Enter to send · Shift+Enter for a new line)"
                                                                   : "Claude Code CLI required for chat"
                                onTextChanged: win.refreshMentions()
                                onCursorPositionChanged: win.refreshMentions()
                                Keys.onReturnPressed: function (event) {
                                    if (mentionPop.visible) {
                                        event.accepted = true
                                        mentionList.acceptCurrent()
                                    } else if (event.modifiers & Qt.ShiftModifier) {
                                        event.accepted = false // newline
                                    } else {
                                        event.accepted = true
                                        win.sendChat()
                                    }
                                }
                                Keys.onEnterPressed: function (event) {
                                    if (mentionPop.visible) {
                                        event.accepted = true
                                        mentionList.acceptCurrent()
                                    } else {
                                        event.accepted = true
                                        win.sendChat()
                                    }
                                }
                                Keys.onUpPressed: function (event) {
                                    if (mentionPop.visible) { event.accepted = true; mentionList.moveUp() }
                                    else event.accepted = false
                                }
                                Keys.onDownPressed: function (event) {
                                    if (mentionPop.visible) { event.accepted = true; mentionList.moveDown() }
                                    else event.accepted = false
                                }
                                Keys.onEscapePressed: function (event) {
                                    if (mentionPop.visible) { event.accepted = true; mentionPop.close() }
                                    else event.accepted = false
                                }
                            }
                        }

                        RoundButton {
                            id: sendBtn
                            text: "➤"
                            font.pixelSize: 16
                            implicitWidth: 40
                            implicitHeight: 40
                            highlighted: true
                            enabled: (chat && chat.available()) && !win.chatBusy
                                     && chatInput.text.trim() !== ""
                            onClicked: win.sendChat()
                            HoverTip { text: "Send" }
                        }
                    }

                    // @-mention picker, floating above the input
                    Popup {
                        id: mentionPop
                        property var matches: []
                        property int at: -1
                        x: 0
                        y: -height - 6
                        width: parent.width
                        // count-based so the frame is right immediately, before
                        // the ListView reports its laid-out contentHeight
                        height: Math.min(224, mentionPop.matches.length * 40 + topPadding + bottomPadding)
                        padding: 4
                        closePolicy: Popup.CloseOnEscape | Popup.CloseOnPressOutside
                        background: Rectangle {
                            radius: 8
                            color: "white"
                            border.width: 1
                            border.color: win.borderColor
                        }
                        contentItem: ListView {
                            id: mentionList
                            clip: true
                            model: mentionPop.matches
                            currentIndex: 0
                            ScrollBar.vertical: ScrollBar {}

                            function acceptCurrent() {
                                if (currentIndex >= 0 && currentIndex < mentionPop.matches.length)
                                    win.applyMention(mentionPop.matches[currentIndex])
                            }
                            function moveUp() { if (currentIndex > 0) currentIndex-- }
                            function moveDown() { if (currentIndex < mentionPop.matches.length - 1) currentIndex++ }

                            delegate: ItemDelegate {
                                id: mrow
                                required property var modelData
                                required property int index
                                width: mentionList.width
                                highlighted: index === mentionList.currentIndex
                                text: "@ " + modelData.title
                                onClicked: win.applyMention(modelData)
                                background: Rectangle {
                                    radius: 6
                                    color: mrow.highlighted ? "#e8eaf6"
                                         : mrow.hovered ? "#eeeeee" : "transparent"
                                }
                            }
                        }
                    }
                }
            }
        }

        // Activity timeline: the technical side of a turn — the commands the agent
        // runs (list_documents, update_document, …), their results and status —
        // kept out of the conversation so the chat shows only the actual reply.
        // Collapsed by default; slides out from the side while the agent works.
        Rectangle {
            id: techPane
            visible: win.chatOpen
            // wider when showing full (untruncated) output
            property real openW: win.activityFull ? 460 : 250
            // animate a plain property (Behaviors can't target attached props),
            // then feed it to the SplitView so the panel slides in/out
            property real pw: win.activityExpanded ? openW : 0
            Behavior on pw {
                NumberAnimation { duration: 280; easing.type: Easing.OutCubic }
            }
            SplitView.preferredWidth: pw
            SplitView.minimumWidth: 0
            clip: true
            color: "#eceff1"

            // fixed-width content pinned to the left edge: as the pane widens the
            // block slides in from the right rather than reflowing every frame
            ColumnLayout {
                anchors.left: parent.left
                width: techPane.openW
                height: parent.height
                spacing: 0

                Rectangle {
                    Layout.fillWidth: true
                    implicitHeight: 48
                    color: "#cfd8dc"
                    RowLayout {
                        anchors.fill: parent
                        anchors.leftMargin: 14
                        anchors.rightMargin: 4
                        spacing: 2
                        Label {
                            text: "Activity"
                            Layout.fillWidth: true
                            font.pixelSize: 15
                            font.weight: Font.Medium
                            color: "#455a64"
                        }
                        ToolButton {
                            text: win.activityFull ? "Collapse" : "Expand"
                            font.capitalization: Font.MixedCase
                            font.pixelSize: 12
                            Material.foreground: "#455a64"
                            enabled: techModel.count > 0
                            onClicked: win.activityFull = !win.activityFull
                            HoverTip { text: win.activityFull ? "Truncate long output"
                                                             : "Show full output" }
                        }
                        ToolButton {
                            text: "✕"
                            implicitWidth: 32
                            implicitHeight: 32
                            Material.foreground: "#455a64"
                            onClicked: win.activityPinned = false
                            HoverTip { text: "Hide the activity log" }
                        }
                    }
                }

                ListView {
                    id: techList
                    Layout.fillWidth: true
                    Layout.fillHeight: true
                    clip: true
                    model: techModel
                    spacing: 0
                    topMargin: 10
                    bottomMargin: 10
                    ScrollBar.vertical: ScrollBar {}

                    Label {
                        anchors.centerIn: parent
                        width: parent.width - 32
                        visible: techModel.count === 0
                        horizontalAlignment: Text.AlignHCenter
                        wrapMode: Text.Wrap
                        opacity: 0.55
                        font.pixelSize: 12
                        color: "#607d8b"
                        text: "Commands the assistant runs and their output appear here."
                    }

                    delegate: Item {
                        id: ev
                        required property var model
                        width: techList.width
                        implicitHeight: evCol.implicitHeight + 14
                        readonly property bool isTool: (model.tool || "") !== ""
                        readonly property bool isErr: model.kind === "error"
                                                    || model.text.indexOf("!") === 0
                        // tool results are the indented "↳" lines; dim them a touch
                        readonly property bool isResult: model.text.indexOf("↳") === 0
                                                       || model.text.indexOf("   ↳") === 0

                        // continuous rail + a dot per event
                        Rectangle {
                            x: 15
                            width: 2
                            height: parent.height
                            color: "#b0bec5"
                        }
                        Rectangle {
                            x: 11
                            y: 7
                            width: 10
                            height: 10
                            radius: 5
                            color: ev.isErr ? "#c62828" : ev.isTool ? "#3949ab"
                                            : ev.isResult ? "#b0bec5" : "#789098"
                            border.width: 2
                            border.color: "#eceff1"
                        }
                        Column {
                            id: evCol
                            x: 32
                            y: 4
                            width: parent.width - 40
                            spacing: 2
                            // the tool name, shown prominently so it's clear which
                            // tool the agent called
                            Label {
                                visible: ev.isTool
                                width: parent.width
                                text: ev.model.tool
                                font.family: "monospace"
                                font.pixelSize: 12
                                font.weight: Font.DemiBold
                                color: "#283593"
                                elide: Text.ElideRight
                            }
                            Label {
                                visible: ev.model.text !== ""
                                width: parent.width
                                text: ev.model.text
                                wrapMode: Text.Wrap
                                // truncate to a few lines unless the user expanded the log
                                maximumLineCount: win.activityFull ? 100000 : 4
                                elide: Text.ElideRight
                                font.family: "monospace"
                                font.pixelSize: 11
                                color: ev.isErr ? "#c62828" : ev.isResult ? "#607d8b" : "#455a64"
                            }
                        }
                    }
                }
            }
        }
    }

    ListModel { id: chatModel }
    ListModel { id: techModel }

    Connections {
        target: chat
        function onTurnStarted() { win.chatBusy = true }
        function onTurnFinished() { win.chatBusy = false }
        function onAssistantText(text) {
            chatModel.append({ kind: "assistant", text: text })
            Qt.callLater(win.chatScrollEnd)
        }
        // technical events go to the Activity timeline, not the conversation
        function onToolActivity(line) {
            // tool calls arrive as "• <name>  <args>"; split the name out so it
            // can be shown prominently ("which tool was called")
            if (line.indexOf("• ") === 0) {
                var body = line.substring(2)
                var sp = body.indexOf("  ")
                var nm = sp >= 0 ? body.substring(0, sp) : body
                var rest = sp >= 0 ? body.substring(sp + 2).trim() : ""
                techModel.append({ kind: "tool", tool: nm, text: rest })
            } else if (line.indexOf("thinking: ") === 0) {
                techModel.append({ kind: "thinking", tool: "", text: line.substring(10) })
            } else {
                techModel.append({ kind: "tool", tool: "", text: line })
            }
            // keep the log open after the turn so the tool calls stay reviewable
            win.activityPinned = true
            Qt.callLater(win.techScrollEnd)
        }
        function onNote(line) {
            techModel.append({ kind: "note", tool: "", text: line })
            Qt.callLater(win.techScrollEnd)
        }
        function onErrorOccurred(message) {
            // failures stay in the conversation so they're not missed
            chatModel.append({ kind: "error", text: message })
            win.chatBusy = false
            Qt.callLater(win.chatScrollEnd)
        }
    }

    // Settings → AI Provider: provider + API key + model, stored in QSettings.
    // ANTHROPIC_API_KEY in the environment takes precedence over the saved key.
    Dialog {
        id: aiDialog
        objectName: "aiDialog"
        title: "AI Provider"
        modal: true
        x: (win.width - width) / 2
        y: (win.height - height) / 3
        onAboutToShow: {
            aiBackendBox.currentIndex = reviser.backend() === "claude-code" ? 0 : 1
            aiKeyField.text = reviser.savedApiKey()
            aiModelField.text = reviser.model()
            showTermSwitch.checked = reviser.showTerminal()
        }

        ColumnLayout {
            spacing: 10

            ComboBox {
                id: aiBackendBox
                Layout.fillWidth: true
                model: ["Claude Code (subscription)", "Anthropic API key"]
                readonly property string backendId: currentIndex === 0 ? "claude-code" : "api"
            }
            Label {
                visible: aiBackendBox.backendId === "claude-code"
                Layout.preferredWidth: 340
                wrapMode: Text.Wrap
                font.pixelSize: 12
                opacity: 0.7
                text: (reviser && reviser.cliAvailable())
                      ? "Uses your logged-in Claude Code CLI — no API key needed. "
                        + "Revisions run through the MCP server and appear live."
                      : "Claude Code CLI not found on PATH — install it and log in, "
                        + "or use an API key instead."
            }
            TextField {
                id: aiKeyField
                visible: aiBackendBox.backendId === "api"
                Layout.preferredWidth: 340
                echoMode: TextInput.Password
                placeholderText: "API key (or set ANTHROPIC_API_KEY)"
            }
            TextField {
                id: aiModelField
                Layout.fillWidth: true
                placeholderText: "Model"
            }
            Switch {
                id: showTermSwitch
                visible: aiBackendBox.backendId === "claude-code"
                text: "Show Claude output while revising"
                font.pixelSize: 13
            }
            RowLayout {
                Layout.fillWidth: true
                Item { Layout.fillWidth: true }
                Button {
                    text: "Cancel"
                    flat: true
                    font.capitalization: Font.MixedCase
                    onClicked: aiDialog.close()
                }
                Button {
                    text: "Save"
                    highlighted: true
                    font.capitalization: Font.MixedCase
                    onClicked: {
                        reviser.saveSettings(aiBackendBox.backendId,
                                             aiKeyField.text, aiModelField.text,
                                             showTermSwitch.checked)
                        aiDialog.close()
                    }
                }
            }
        }
    }

    // Settings → MCP Server Info: tool docs generated from the server's TOOLS
    // list, plus a copyable client config for this install.
    Window {
        id: mcpInfoWin
        objectName: "mcpInfoWin"
        title: "MCP Server Info"
        width: 680
        height: 760
        minimumWidth: 420
        minimumHeight: 300
        color: "#fafafa"

        function schemaLines(tool) {
            var props = tool.inputSchema.properties
            var req = tool.inputSchema.required || []
            var keys = Object.keys(props)
            if (keys.length === 0)
                return "(no arguments)"
            return keys.map(function (k) {
                var p = props[k]
                return "• " + k + " (" + p.type
                        + (req.indexOf(k) >= 0 ? ", required" : "") + ")"
                        + (p.description ? " — " + p.description : "")
            }).join("\n")
        }

        Flickable {
            anchors.fill: parent
            contentHeight: infoCol.height + 48
            clip: true
            ScrollBar.vertical: ScrollBar {}

            Column {
                id: infoCol
                x: 24
                y: 24
                width: mcpInfoWin.width - 48
                spacing: 18

                Label {
                    text: "MCP Server Tools"
                    font.pixelSize: 20
                    font.weight: Font.Medium
                    color: "#3949ab"
                }
                Label {
                    width: infoCol.width
                    wrapMode: Text.Wrap
                    font.pixelSize: 13
                    opacity: 0.7
                    text: "The recall-mcp server speaks MCP over stdio and exposes these tools "
                          + "to AI agents. All reads and writes go to the same database as this app."
                }

                Repeater {
                    model: mcpTools
                    delegate: Column {
                        id: toolEntry
                        required property var modelData
                        width: infoCol.width
                        spacing: 4

                        Label {
                            text: toolEntry.modelData.name
                            font.family: "monospace"
                            font.pixelSize: 15
                            font.weight: Font.Bold
                            color: "#3949ab"
                        }
                        Label {
                            width: toolEntry.width
                            wrapMode: Text.Wrap
                            font.pixelSize: 13
                            text: toolEntry.modelData.description
                        }
                        Label {
                            width: toolEntry.width
                            wrapMode: Text.Wrap
                            font.pixelSize: 12
                            font.family: "monospace"
                            opacity: 0.75
                            text: mcpInfoWin.schemaLines(toolEntry.modelData)
                        }
                    }
                }

                Label {
                    text: "Client configuration"
                    font.pixelSize: 20
                    font.weight: Font.Medium
                    color: "#3949ab"
                }
                Label {
                    width: infoCol.width
                    wrapMode: Text.Wrap
                    font.pixelSize: 13
                    opacity: 0.7
                    text: "Add this to your MCP client's config (e.g. Claude Code or Claude "
                          + "Desktop) to let agents edit this Recall instance:"
                }

                Rectangle {
                    width: infoCol.width
                    height: configText.height + 24
                    radius: 6
                    color: "#263238"

                    TextEdit {
                        id: configText
                        x: 12
                        y: 12
                        width: parent.width - 24
                        readOnly: true
                        selectByMouse: true
                        wrapMode: TextEdit.Wrap
                        font.family: "monospace"
                        font.pixelSize: 12
                        color: "#eceff1"
                        text: mcpConfigJson
                    }
                    ToolButton {
                        id: cfgCopyBtn
                        property bool copied: false
                        text: copied ? "Copied!" : "Copy"
                        font.pixelSize: 11
                        font.capitalization: Font.MixedCase
                        implicitHeight: 28
                        anchors.top: parent.top
                        anchors.right: parent.right
                        anchors.margins: 6
                        Material.foreground: "#eceff1"
                        background: Rectangle {
                            radius: 4
                            color: cfgCopyBtn.down ? "#607d8b"
                                 : cfgCopyBtn.hovered ? "#546e7a" : "#455a64"
                        }
                        onClicked: {
                            highlighter.copy(mcpConfigJson)
                            copied = true
                            cfgCopiedReset.restart()
                        }
                        Timer { id: cfgCopiedReset; interval: 1200; onTriggered: cfgCopyBtn.copied = false }
                        HoverTip { text: "Copy config JSON" }
                    }
                }

                // one-click registration for interactive Claude Code sessions;
                // the in-app Revise button passes this config inline and needs none
                Row {
                    spacing: 12
                    visible: (reviser && reviser.cliAvailable())

                    Button {
                        id: registerBtn
                        text: "Register with Claude Code"
                        font.capitalization: Font.MixedCase
                        highlighted: true
                        onClicked: {
                            registerBtn.enabled = false
                            reviser.registerMcp()
                        }
                        HoverTip { text: "Runs: claude mcp add --scope user recall — makes these tools available in your own Claude Code sessions" }
                    }
                    Label {
                        id: registerStatus
                        anchors.verticalCenter: registerBtn.verticalCenter
                        font.pixelSize: 13
                        text: ""
                    }
                    Connections {
                        target: reviser
                        function onRegisterResult(ok, message) {
                            registerBtn.enabled = true
                            registerStatus.text = message
                            registerStatus.color = ok ? "#2e7d32" : "#c62828"
                        }
                    }
                }
            }
        }
    }

    // live progress from the headless claude run, terminal-styled; opened
    // automatically when revising if enabled in AI Provider settings
    Window {
        id: claudeConsole
        objectName: "claudeConsole"
        title: "Claude — revision output"
        width: 640
        height: 440
        minimumWidth: 360
        minimumHeight: 220
        color: "#263238"

        function log(line) {
            consoleText.text += (consoleText.text === "" ? "" : "\n\n") + line
            consoleFlick.contentY = Math.max(0, consoleText.height - consoleFlick.height + 24)
        }

        Flickable {
            id: consoleFlick
            anchors.fill: parent
            anchors.margins: 4
            contentHeight: consoleText.height + 24
            clip: true
            ScrollBar.vertical: ScrollBar {}

            TextEdit {
                id: consoleText
                x: 12
                y: 12
                width: consoleFlick.width - 24
                readOnly: true
                selectByMouse: true
                wrapMode: TextEdit.Wrap
                textFormat: TextEdit.PlainText
                font.family: "monospace"
                font.pixelSize: 12
                color: "#eceff1"
            }
        }
    }

    Connections {
        target: reviser

        function onOutputLine(line) {
            claudeConsole.log(line)
        }
        function onStarted(docId) {
            if (reviser.showTerminal() && reviser.backend() === "claude-code") {
                consoleText.text = ""
                claudeConsole.show()
            }
        }
    }
}
