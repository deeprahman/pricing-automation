from dataclasses import dataclass

from sqlalchemy import func, select
from sqlalchemy.orm import Session

from auth import get_password_hash, verify_password
from models_admin import LoginAttempt, User
from schemas import UserRegister


@dataclass(slots=True)
class AuthenticationResult:
    user: User | None
    failure_reason: str | None = None


class UserService:
    def __init__(self, db: Session) -> None:
        self.db = db

    def get_user_by_id(self, user_id: int) -> User | None:
        return self.db.get(User, user_id)

    def get_user_by_email(self, email: str) -> User | None:
        stmt = select(User).where(User.email == email.lower())
        return self.db.execute(stmt).scalar_one_or_none()

    def get_user_by_username(self, username: str) -> User | None:
        stmt = select(User).where(User.username == username.lower())
        return self.db.execute(stmt).scalar_one_or_none()

    def email_exists(self, email: str) -> bool:
        return self.get_user_by_email(email) is not None

    def username_exists(self, username: str) -> bool:
        return self.get_user_by_username(username) is not None

    def create_user(self, payload: UserRegister) -> User:
        normalized_email = payload.email.lower()
        normalized_username = payload.username.lower()

        if self.email_exists(normalized_email):
            raise ValueError("Email already registered")
        if self.username_exists(normalized_username):
            raise ValueError("Username already registered")

        total_users = self.db.execute(select(func.count()).select_from(User)).scalar_one()
        is_first_user = total_users == 0

        user = User(
            email=normalized_email,
            username=normalized_username,
            full_name=payload.full_name,
            hashed_password=get_password_hash(payload.password),
            is_active=False,
            is_admin=is_first_user,
        )
        self.db.add(user)
        self.db.commit()
        self.db.refresh(user)
        return user

    def authenticate_user(
        self,
        email: str,
        password: str,
        *,
        ip_address: str | None = None,
    ) -> AuthenticationResult:
        normalized_email = email.lower()
        user = self.get_user_by_email(normalized_email)

        if user is None:
            self._record_login_attempt(
                email=normalized_email,
                successful=False,
                ip_address=ip_address,
                reason="User not found",
            )
            return AuthenticationResult(user=None, failure_reason="invalid_credentials")

        if not user.is_active:
            self._record_login_attempt(
                email=normalized_email,
                successful=False,
                ip_address=ip_address,
                reason="User inactive",
            )
            return AuthenticationResult(user=None, failure_reason="inactive")

        password_valid = verify_password(password, user.hashed_password)
        self._record_login_attempt(
            email=normalized_email,
            successful=password_valid,
            ip_address=ip_address,
            reason=None if password_valid else "Invalid password",
        )

        if not password_valid:
            return AuthenticationResult(user=None, failure_reason="invalid_credentials")
        return AuthenticationResult(user=user)

    def _record_login_attempt(
        self,
        *,
        email: str,
        successful: bool,
        ip_address: str | None,
        reason: str | None,
    ) -> None:
        attempt = LoginAttempt(
            email=email,
            successful=successful,
            ip_address=ip_address,
            reason=reason,
        )
        self.db.add(attempt)
        self.db.commit()
