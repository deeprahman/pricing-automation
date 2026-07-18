import secrets
from datetime import datetime, timedelta, timezone

from starlette.requests import Request
from starlette.responses import Response
from starlette_admin.auth import AdminUser, AuthProvider
from starlette_admin.exceptions import FormValidationError, LoginFailed

from auth import ACCESS_TOKEN_EXPIRE_MINUTES
from database_dual_existing_auto import AdminSessionLocal
from models_admin import AdminSession, User
from user_service import UserService

SESSION_USER_ID_KEY = "pws_admin_user_id"
SESSION_USER_EMAIL_KEY = "pws_admin_user_email"
SESSION_IS_ADMIN_KEY = "pws_admin_is_admin"
SESSION_TOKEN_KEY = "pws_admin_session_token"
SESSION_REMEMBER_ME_KEY = "pws_admin_remember_me"


def _request_ip(request: Request) -> str | None:
    if request.client is None:
        return None
    return request.client.host


class JWTAuthBackend(AuthProvider):
    async def login(
        self,
        username: str,
        password: str,
        remember_me: bool,
        request: Request,
        response: Response,
    ) -> Response:
        username = (username or "").strip().lower()
        password = password or ""

        errors: dict[str, str] = {}
        if not username:
            errors["username"] = "Username/email is required"
        if not password:
            errors["password"] = "Password is required"
        if errors:
            raise FormValidationError(errors)

        with AdminSessionLocal() as db:
            user_service = UserService(db)
            auth_result = user_service.authenticate_user(
                username,
                password,
                ip_address=_request_ip(request),
            )
            user = auth_result.user
            if user is None or not user.is_admin:
                raise LoginFailed("Invalid credentials or insufficient privileges")

            now = datetime.now(timezone.utc)
            expiry = now + (
                timedelta(days=7)
                if remember_me
                else timedelta(minutes=ACCESS_TOKEN_EXPIRE_MINUTES)
            )
            session_token = secrets.token_urlsafe(48)

            db.add(
                AdminSession(
                    user_id=user.id,
                    session_token=session_token,
                    ip_address=_request_ip(request),
                    user_agent=request.headers.get("user-agent"),
                    expires_at=expiry,
                    is_active=True,
                )
            )
            db.commit()

            request.session.update(
                {
                    SESSION_USER_ID_KEY: user.id,
                    SESSION_USER_EMAIL_KEY: user.email,
                    SESSION_IS_ADMIN_KEY: True,
                    SESSION_TOKEN_KEY: session_token,
                    SESSION_REMEMBER_ME_KEY: remember_me,
                }
            )
        return response

    async def is_authenticated(self, request: Request) -> bool:
        user_id = request.session.get(SESSION_USER_ID_KEY)
        session_token = request.session.get(SESSION_TOKEN_KEY)
        is_admin = request.session.get(SESSION_IS_ADMIN_KEY, False)

        if not user_id or not session_token or not is_admin:
            return False

        now = datetime.now(timezone.utc)
        with AdminSessionLocal() as db:
            user = db.get(User, int(user_id))
            if user is None or not user.is_active or not user.is_admin:
                return False

            admin_session = (
                db.query(AdminSession)
                .filter(
                    AdminSession.user_id == user.id,
                    AdminSession.session_token == session_token,
                    AdminSession.is_active.is_(True),
                )
                .first()
            )
            if admin_session is None:
                return False
            if admin_session.expires_at <= now:
                admin_session.is_active = False
                db.commit()
                return False

            request.state.user = user
            return True

    def get_admin_user(self, request: Request) -> AdminUser | None:
        if not request.session.get(SESSION_IS_ADMIN_KEY):
            return None

        user = getattr(request.state, "user", None)
        if user is not None:
            display_name = user.full_name or user.username or user.email
            return AdminUser(username=display_name)

        session_email = request.session.get(SESSION_USER_EMAIL_KEY)
        if session_email:
            return AdminUser(username=session_email)
        return None

    async def logout(self, request: Request, response: Response) -> Response:
        user_id = request.session.get(SESSION_USER_ID_KEY)
        session_token = request.session.get(SESSION_TOKEN_KEY)

        if user_id and session_token:
            with AdminSessionLocal() as db:
                admin_session = (
                    db.query(AdminSession)
                    .filter(
                        AdminSession.user_id == int(user_id),
                        AdminSession.session_token == session_token,
                        AdminSession.is_active.is_(True),
                    )
                    .first()
                )
                if admin_session is not None:
                    admin_session.is_active = False
                    db.commit()

        request.session.clear()
        return response
