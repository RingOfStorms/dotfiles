# ========================================================================== #
#                                                                            #
#    ConnectPRO Serial KVM Switch GPIO Driver for PiKVM (KVMD).              #
#                                                                            #
#    Installed to /usr/lib/python3.*/site-packages/kvmd/plugins/ugpio/       #
#    as `connectpro.py`.                                                     #
#                                                                            #
#    Tracks active channel both when switched from the PiKVM Web UI and      #
#    when physical front-panel buttons 1..4 are pressed on the ConnectPRO    #
#    (which broadcast `CH1\r\n` .. `CH4\r\n` at 115200 8N1).                 #
#                                                                            #
# ========================================================================== #

import errno
import multiprocessing
import re
import time
from typing import Any, Callable, Final

import serial

from ... import aiomulti, aiotools
from ...logging import get_logger
from ...validators.basic import valid_float_f01, valid_number
from ...validators.hw import valid_tty_speed
from ...validators.os import valid_abs_path
from ...yamlconf import Option, Section
from . import BaseUserGpioDriver, GpioDriverOfflineError


class Plugin(BaseUserGpioDriver):  # pylint: disable=too-many-instance-attributes
    def __init__(
        self,
        instance_name: str,
        notifier: aiotools.AioNotifier,
        c: Section,
    ) -> None:
        super().__init__(instance_name, notifier, c)

        self.__device_path: Final[str] = c.device
        self.__speed: Final[int] = c.speed
        self.__read_timeout: Final[float] = c.read_timeout
        self.__default_channel: Final[int] = c.default_channel

        self.__ctl_q: aiomulti.AioMpQueue[int] = aiomulti.AioMpQueue()
        self.__ch_q: aiomulti.AioMpQueue[int | None] = aiomulti.AioMpQueue()
        self.__ch: int | None = -1

        self.__proc = aiomulti.AioMpProcess(
            f"gpio-connectpro-{self._instance_name}",
            self.__serial_worker,
        )
        self.__stop_event = multiprocessing.Event()

    @classmethod
    def get_plugin_options(cls) -> dict:
        return {
            "device":          Option("/dev/ttyUSB0", type=valid_abs_path),
            "speed":           Option(115200,         type=valid_tty_speed),
            "read_timeout":    Option(0.2,            type=valid_float_f01),
            "default_channel": Option(0,              type=valid_number.mk(min=-1, max=7)),
        }

    @classmethod
    def get_pin_validator(cls) -> Callable[[Any], Any]:
        return valid_number.mk(min=0, max=7, name="ConnectPRO channel")

    async def prepare(self) -> None:
        self.__proc.start()

    async def run(self) -> None:
        while True:
            (got, ch) = await self.__ch_q.async_fetch_last(1)
            if got and self.__ch != ch:
                self.__ch = ch
                self._notifier.notify()

    async def cleanup(self) -> None:
        if self.__proc.is_alive():
            self.__stop_event.set()
            await self.__proc.async_join()

    async def read(self, pin: str) -> bool:
        if not self.__is_online():
            raise GpioDriverOfflineError(self)
        return (self.__ch == int(pin))

    async def write(self, pin: str, state: bool) -> None:
        if not self.__is_online():
            raise GpioDriverOfflineError(self)
        if state:
            self.__ctl_q.put_nowait(int(pin))

    def __is_online(self) -> bool:
        return (
            self.__proc.is_alive()
            and self.__ch is not None
        )

    def __serial_worker(self) -> None:
        logger = get_logger(0)
        while not self.__stop_event.is_set():
            try:
                with self.__get_serial() as tty:
                    data = b""
                    if self.__default_channel >= 0:
                        self.__send_channel(tty, self.__default_channel)
                        self.__ch_q.put_nowait(self.__default_channel)
                    else:
                        self.__ch_q.put_nowait(-1)

                    while not self.__stop_event.is_set():
                        (ch, data) = self.__recv_channel(tty, data)
                        if ch is not None:
                            self.__ch_q.put_nowait(ch)

                        (got, ctl_ch) = self.__ctl_q.fetch_last(0.05)
                        if got:
                            assert ctl_ch is not None
                            self.__send_channel(tty, ctl_ch)
                            self.__ch_q.put_nowait(ctl_ch)

            except Exception as ex:
                self.__ch_q.put_nowait(None)
                if isinstance(ex, serial.SerialException) and ex.errno == errno.ENOENT:  # pylint: disable=no-member
                    logger.error("Missing %s serial device: %s", self, self.__device_path)
                else:
                    logger.exception("Unexpected %s error", self)
                time.sleep(1)

    def __get_serial(self) -> serial.Serial:
        return serial.Serial(self.__device_path, self.__speed, timeout=self.__read_timeout)

    def __recv_channel(self, tty: serial.Serial, data: bytes) -> tuple[int | None, bytes]:
        ch: int | None = None
        if tty.in_waiting:
            data += tty.read_all()
            found = list(re.finditer(rb"CH([1-8])\r?\n?", data))
            if found:
                last = found[-1]
                ch = int(last.group(1)) - 1
                data = data[last.end(0):]
            elif len(data) > 64:
                data = data[-16:]
        return (ch, data)

    def __send_channel(self, tty: serial.Serial, ch: int) -> None:
        assert 0 <= ch <= 7
        cmd = f"CH{ch + 1}\r\n".encode("ascii")
        tty.write(cmd)
        tty.flush()

    def __str__(self) -> str:
        return f"ConnectPRO({self._instance_name})"

    __repr__ = __str__
