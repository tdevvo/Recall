# Recall GUI entry point. Python port of src/main.cpp.
import json
import sys
from pathlib import Path

from PySide6.QtCore import QCoreApplication, QObject, QTimer, QUrl, Slot
from PySide6.QtGui import (QColor, QFont, QGuiApplication, QIcon,
                           QTextBlockFormat, QTextCharFormat, QTextCursor,
                           QTextDocument, QTextFormat)
from PySide6.QtQml import QQmlApplicationEngine
from PySide6.QtQuickControls2 import QQuickStyle

from . import __version__
from .chat import ChatAgent
from .doctreemodel import DocTreeModel
from .mcp_server import TOOLS, client_config
from .revise import Reviser
from .store import Store, default_db_path

CLARIFY_BG = QColor("#fff8e1")        # cream, matches the request-bubble scheme
CLARIFY_HOVER_BG = QColor("#ffe082")  # deeper gold while hovered
CODE_FG = QColor("#eceff1")           # light code text; QML draws the dark slab

# Reader block spacing. Adjacent block margins collapse to the larger of the
# two, so each value below is the full gap that side contributes.
PARA_MARGIN = 14        # plain paragraphs, blockquotes, etc.
LIST_MARGIN = 6         # tighter rhythm between items within a list
HEADING_BOTTOM = 10
CODE_MARGIN = 30        # bottom gap outside the slab; QML's slab overdraws 18
                        # of it, leaving a 12px visible gap below the code
CODE_TOP = 46           # larger top gap: the slab overdraws 32 of it for a
                        # header strip that holds the copy button clear of the
                        # code, leaving a 14px visible gap above the block


class Highlighter(QObject):
    """Styles the reader's QTextDocument after each markdown load.

    QML TextEdit can't format arbitrary ranges itself, so the reader hands us
    its textDocument. We add heading margins, paint code-block runs grey (and
    report them for copy buttons), give clarification quotes a gold background,
    and report their ranges back so QML can hit-test hover/click.
    """

    @Slot("QVariant", "QVariantList", result="QVariantMap")
    def apply(self, quick_doc, clarifs):
        doc = quick_doc.textDocument()
        code = self._style_blocks(doc)
        out = []
        for c in clarifs:
            r = dict(c)
            cur = doc.find(c["quoted_text"])
            if cur.isNull():
                # ponytail: QTextDocument.find can't match across paragraphs —
                # such quotes get no inline mark, but stay in the list panel
                r["start"], r["end"] = -1, -1
            else:
                r["start"], r["end"] = cur.selectionStart(), cur.selectionEnd()
                # skip if already gold — repainting mid-stream churns layout
                if cur.charFormat().background().color() != CLARIFY_BG:
                    self._paint(doc, r["start"], r["end"], CLARIFY_BG)
            out.append(r)
        return {"clarifs": out, "code": code}

    @Slot("QVariant", int, int, result="QVariantList")
    def lineRects(self, quick_doc, start, end):
        """One rect per wrapped text line in [start, end) — lets QML draw
        revise sheens that hug the text instead of spanning the viewport."""
        doc = quick_doc.textDocument()
        end = min(end, max(0, doc.characterCount() - 1))
        rects = []
        pos = start
        while pos < end:
            block = doc.findBlock(pos)
            if not block.isValid():
                break
            layout = block.layout()
            line = layout.lineForTextPosition(pos - block.position())
            if not line.isValid():
                pos = block.position() + block.length()  # unlaid block: skip it
                continue
            line_end = block.position() + line.textStart() + line.textLength()
            seg_end = min(end, line_end)
            x0, _ = line.cursorToX(pos - block.position())
            x1, _ = line.cursorToX(seg_end - block.position())
            origin = layout.position()
            rects.append({"x": origin.x() + min(x0, x1),
                          "y": origin.y() + line.y(),
                          "width": abs(x1 - x0),
                          "height": line.height()})
            pos = seg_end if seg_end > pos else pos + 1
        return rects

    @Slot("QVariant", int, int, bool)
    def hover(self, quick_doc, start, end, on):
        self._paint(quick_doc.textDocument(), start, end,
                    CLARIFY_HOVER_BG if on else CLARIFY_BG)

    @Slot(str)
    def copy(self, text):
        QGuiApplication.clipboard().setText(text)

    @Slot("QVariant", int, int, str)
    def copyAsMarkdown(self, quick_doc, start, end, full_source):
        """Copy the selection to the clipboard as Markdown *source* (not the
        rendered text), so pasting into another document/template reproduces the
        original formatting. Selecting the whole document copies the exact source;
        a partial selection is round-tripped back to Markdown."""
        doc = quick_doc.textDocument()
        total = max(0, doc.characterCount() - 1)
        if start <= 0 and end >= total:
            md = full_source
        else:
            cur = QTextCursor(doc)
            cur.setPosition(start)
            cur.setPosition(end, QTextCursor.KeepAnchor)
            tmp = QTextDocument()
            QTextCursor(tmp).insertFragment(cur.selection())
            md = tmp.toMarkdown().rstrip("\n")
        QGuiApplication.clipboard().setText(md)

    @staticmethod
    def _style_blocks(doc):
        """Heading spacing + grey code blocks; returns code runs for copy buttons.

        Idempotent: formats already in place are left untouched, so re-applies
        on an unchanged document (clarif refreshes mid-revision) don't trigger
        relayout churn.
        """
        runs = []
        run = None
        prev_code_block = None
        block = doc.begin()
        while block.isValid():
            bf = block.blockFormat()
            is_heading = bf.headingLevel() > 0
            if is_heading:
                top = 30 - 4 * min(bf.headingLevel(), 4)
                if bf.topMargin() != top:
                    nbf = QTextBlockFormat()
                    nbf.setTopMargin(top)
                    nbf.setBottomMargin(HEADING_BOTTOM)
                    QTextCursor(block).mergeBlockFormat(nbf)
            # markdown import marks code lines as non-breakable one-line blocks
            is_code = bf.nonBreakableLines() or bf.hasProperty(QTextFormat.BlockCodeLanguage)
            if is_code:
                # QML's text renderer ignores block backgrounds, so only set
                # margins + light text here; QML draws the dark slab behind
                # the run from the start/end positions we report.
                if run is None:
                    run = {"start": block.position(), "lines": []}
                    if bf.topMargin() != CODE_TOP:
                        nbf = QTextBlockFormat()
                        nbf.setTopMargin(CODE_TOP)
                        QTextCursor(block).mergeBlockFormat(nbf)
                it = block.begin()
                styled = (not it.atEnd() and
                          it.fragment().charFormat().foreground().color() == CODE_FG)
                if not styled:
                    cur = QTextCursor(block)
                    cur.select(QTextCursor.BlockUnderCursor)
                    cfmt = QTextCharFormat()
                    cfmt.setForeground(CODE_FG)
                    cur.mergeCharFormat(cfmt)
                run["lines"].append(block.text())
                run["end"] = block.position() + max(0, block.length() - 1)
                prev_code_block = block
            else:
                if run is not None:
                    if prev_code_block.blockFormat().bottomMargin() != CODE_MARGIN:
                        nbf = QTextBlockFormat()
                        nbf.setBottomMargin(CODE_MARGIN)
                        QTextCursor(prev_code_block).mergeBlockFormat(nbf)
                    runs.append({"start": run["start"], "end": run["end"],
                                 "text": "\n".join(run["lines"])})
                    run = None
                if not is_heading:
                    # paragraphs, list items, quotes — everything else gets an
                    # explicit vertical rhythm instead of Qt's import defaults
                    margin = LIST_MARGIN if block.textList() else PARA_MARGIN
                    if ((bf.topMargin() != margin or bf.bottomMargin() != margin)
                            and QTextCursor(block).currentTable() is None):
                        nbf = QTextBlockFormat()
                        nbf.setTopMargin(margin)
                        nbf.setBottomMargin(margin)
                        QTextCursor(block).mergeBlockFormat(nbf)
            block = block.next()
        if run is not None:
            # run ends at the document's last block: give it the same bottom
            # margin as the in-loop close, or the slab overdraws past the text
            if prev_code_block.blockFormat().bottomMargin() != CODE_MARGIN:
                nbf = QTextBlockFormat()
                nbf.setBottomMargin(CODE_MARGIN)
                QTextCursor(prev_code_block).mergeBlockFormat(nbf)
            runs.append({"start": run["start"], "end": run["end"],
                         "text": "\n".join(run["lines"])})
        return runs

    @staticmethod
    def _paint(doc, start, end, color):
        cur = QTextCursor(doc)
        cur.setPosition(start)
        cur.setPosition(end, QTextCursor.KeepAnchor)
        fmt = QTextCharFormat()
        fmt.setBackground(color)
        cur.mergeCharFormat(fmt)


def main():
    app = QGuiApplication(sys.argv)
    QCoreApplication.setOrganizationName("Recall")
    QCoreApplication.setApplicationName("Recall")
    icon = Path(__file__).parent / "recall.png"
    if icon.exists():
        app.setWindowIcon(QIcon(str(icon)))
    QQuickStyle.setStyle("Material")
    # humanist body font — softer than the platform default, still professional;
    # falls back to the system font when Open Sans isn't installed
    font = QFont("Open Sans", 10)
    font.setStyleHint(QFont.SansSerif)
    app.setFont(font)

    store = Store(default_db_path())
    model = DocTreeModel(store)
    store.changed.connect(model.reload)
    # parallel tree of template documents (the Templates view swaps to this)
    template_model = DocTreeModel(store, templates=True)
    store.changed.connect(template_model.reload)

    # Pick up writes from the external MCP server: SQLite's data_version pragma
    # changes whenever another connection commits (file watching misses WAL writes).
    poll = QTimer()
    poll.setInterval(750)
    poll.timeout.connect(store.checkExternalChanges)
    poll.start()

    highlighter = Highlighter()
    reviser = Reviser(store)
    chat = ChatAgent(store)

    engine = QQmlApplicationEngine()
    engine.rootContext().setContextProperty("appVersion", __version__)
    engine.rootContext().setContextProperty("store", store)
    engine.rootContext().setContextProperty("docModel", model)
    engine.rootContext().setContextProperty("templateModel", template_model)
    engine.rootContext().setContextProperty("highlighter", highlighter)
    engine.rootContext().setContextProperty("reviser", reviser)
    engine.rootContext().setContextProperty("chat", chat)
    engine.rootContext().setContextProperty("mcpTools", TOOLS)
    engine.rootContext().setContextProperty("mcpConfigJson",
                                            json.dumps(client_config(), indent=2))
    engine.objectCreationFailed.connect(lambda: sys.exit(1))
    engine.load(QUrl.fromLocalFile(str(Path(__file__).parent / "qml" / "Main.qml")))
    return app.exec()


if __name__ == "__main__":
    sys.exit(main())
