from textual.app import App, ComposeResult
from textual.binding import Binding
from textual.containers import Container, Horizontal, ScrollableContainer
from textual.widgets import (
    Button,
    DataTable,
    Footer,
    Header,
    Input,
    RichLog,
    Static,
    Switch,
    Label,
)

from rich.markdown import Markdown


LOG_MD = """

## 这是一个内核管理器

将在这里显示日志
"""


class Title(Static):
    pass


class Load_installed(Container):
    def compose(self) -> ComposeResult:
        yield Button("加载已安装内核", variant="success")

    def on_button_pressed(self, event: Button.Pressed) -> None:
        print(1)


class Load_available(Container):
    def compose(self) -> ComposeResult:
        yield Button("加载软件源里可用内核", variant="success")

    def on_button_pressed(self, event: Button.Pressed) -> None:
        print(1)


class Log(Container):
    def compose(self) -> ComposeResult:
        yield Static(Markdown(LOG_MD))


class Sidebar(Container):
    def compose(self) -> ComposeResult:
        yield Title("内核管理器")


class Body(ScrollableContainer):
    pass


class QuickAccess(Container):
    pass


class LocationLink(Static):
    def __init__(self, label: str, reveal: str) -> None:
        super().__init__(label)
        self.reveal = reveal

    def on_click(self) -> None:
        self.app.query_one(self.reveal).scroll_visible(top=True, duration=0.5)
        self.app.add_note(f"Scrolling to [b]{self.reveal}[/b]")


class Column(Container):
    pass


class Manager(App):
    CSS_PATH = "style.css"
    TITLE = "内核管理器"
    BINDINGS = [
        ("ctrl+b", "toggle_sidebar", "Sidebar"),
        ("ctrl+t", "app.toggle_dark", "Toggle Dark mode"),
        ("ctrl+s", "app.screenshot()", "Screenshot"),
        ("f1", "app.toggle_class('RichLog', '-hidden')", "Notes"),
        Binding("ctrl+q", "app.quit", "Quit", show=True),
    ]

    def compose(self) -> ComposeResult:
        yield Container(
            Header(show_clock=True),
            Body(
                Container(Log(), classes="location-right"),
            ),
            Column(
                Load_installed(),
                classes="location-widgets location-first",
            ),
            Column(
                Load_available(),
                classes="location-widgets location-second",
            ),
        )


if __name__ == "__main__":
    app = Manager()
    app.run()
