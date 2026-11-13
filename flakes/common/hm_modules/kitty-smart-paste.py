"""Keep native text/enhanced paste; let legacy TUIs handle clipboard images."""

from kittens.tui.handler import result_handler


def main(args):
    raise SystemExit("Run this kitten from a Kitty key binding.")


@result_handler(no_ui=True)
def handle_result(args, answer, target_window_id, boss):
    window = boss.window_id_map.get(target_window_id)
    if window is None:
        return

    # Enhanced paste already delivers MIME types, including images, to the TUI.
    if not window.screen.paste_events and any(
        mime.startswith("image/")
        for mime in boss.clipboard.get_available_mime_types_for_paste()
    ):
        # Encode for the child's keyboard protocol (legacy Ctrl+V or CSI-u).
        # Do not bracket this key as pasted text, or paste a second time.
        window.send_key("ctrl+v")
    else:
        boss.paste_from_clipboard()
