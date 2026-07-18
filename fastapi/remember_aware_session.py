from __future__ import annotations

import json
import typing
from base64 import b64decode, b64encode

import itsdangerous
from starlette.datastructures import MutableHeaders, Secret
from starlette.requests import HTTPConnection
from starlette.types import ASGIApp, Message, Receive, Scope, Send


class RememberAwareSessionMiddleware:
    """Session middleware that makes cookie persistence depend on a session flag."""

    def __init__(
        self,
        app: ASGIApp,
        secret_key: str | Secret,
        session_cookie: str = "session",
        max_age: int | None = 14 * 24 * 60 * 60,
        path: str = "/",
        same_site: typing.Literal["lax", "strict", "none"] = "lax",
        https_only: bool = False,
        domain: str | None = None,
        remember_flag_key: str = "pws_admin_remember_me",
    ) -> None:
        self.app = app
        self.signer = itsdangerous.TimestampSigner(str(secret_key))
        self.session_cookie = session_cookie
        # Keep Starlette-compatible signature validation max age.
        self.max_age = max_age
        self.path = path
        self.remember_flag_key = remember_flag_key
        self.security_flags = "httponly; samesite=" + same_site
        if https_only:
            self.security_flags += "; secure"
        if domain is not None:
            self.security_flags += f"; domain={domain}"

    async def __call__(self, scope: Scope, receive: Receive, send: Send) -> None:
        if scope["type"] not in ("http", "websocket"):
            await self.app(scope, receive, send)
            return

        connection = HTTPConnection(scope)
        initial_session_was_empty = True

        if self.session_cookie in connection.cookies:
            data = connection.cookies[self.session_cookie].encode("utf-8")
            try:
                data = self.signer.unsign(data, max_age=self.max_age)
                scope["session"] = json.loads(b64decode(data))
                initial_session_was_empty = False
            except itsdangerous.BadSignature:
                scope["session"] = {}
        else:
            scope["session"] = {}

        async def send_wrapper(message: Message) -> None:
            if message["type"] == "http.response.start":
                if scope["session"]:
                    data = b64encode(json.dumps(scope["session"]).encode("utf-8"))
                    data = self.signer.sign(data)
                    headers = MutableHeaders(scope=message)
                    remember_me = bool(scope["session"].get(self.remember_flag_key, False))
                    max_age_segment = (
                        f"Max-Age={self.max_age}; "
                        if remember_me and self.max_age
                        else ""
                    )
                    header_value = (
                        f"{self.session_cookie}={data.decode('utf-8')}; "
                        f"path={self.path}; {max_age_segment}{self.security_flags}"
                    )
                    headers.append("Set-Cookie", header_value)
                elif not initial_session_was_empty:
                    headers = MutableHeaders(scope=message)
                    header_value = (
                        f"{self.session_cookie}=null; "
                        f"path={self.path}; "
                        "expires=Thu, 01 Jan 1970 00:00:00 GMT; "
                        f"{self.security_flags}"
                    )
                    headers.append("Set-Cookie", header_value)
            await send(message)

        await self.app(scope, receive, send_wrapper)
