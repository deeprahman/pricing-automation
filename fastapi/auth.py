import os
from datetime import datetime, timedelta, timezone
from typing import Any

from fastapi import Depends, HTTPException, Request, status
from fastapi.security import OAuth2PasswordBearer
from jose import JWTError, jwt
from passlib.context import CryptContext
from sqlalchemy.orm import Session

from database_dual_existing_auto import get_admin_db
from models_admin import User
from schemas import TokenData

SECRET_KEY = os.getenv("SECRET_KEY", "change-me-in-production")
ALGORITHM = "HS256"
ACCESS_TOKEN_EXPIRE_MINUTES = int(os.getenv("ACCESS_TOKEN_EXPIRE_MINUTES", "30"))
ACCESS_TOKEN_REMEMBER_DAYS = int(os.getenv("ACCESS_TOKEN_REMEMBER_DAYS", "7"))

pwd_context = CryptContext(schemes=["bcrypt"], deprecated="auto")
oauth2_scheme = OAuth2PasswordBearer(tokenUrl="/pwsadmin/api/auth/login", auto_error=False)


def verify_password(plain_password: str, hashed_password: str) -> bool:
    return pwd_context.verify(plain_password, hashed_password)


def get_password_hash(password: str) -> str:
    return pwd_context.hash(password)


def create_access_token(data: dict[str, Any], expires_delta: timedelta | None = None) -> str:
    to_encode = data.copy()
    expire = datetime.now(timezone.utc) + (
        expires_delta or timedelta(minutes=ACCESS_TOKEN_EXPIRE_MINUTES)
    )
    to_encode.update({"exp": expire})
    return jwt.encode(to_encode, SECRET_KEY, algorithm=ALGORITHM)


def get_login_expires_delta(*, remember_me: bool) -> timedelta:
    if remember_me:
        return timedelta(days=ACCESS_TOKEN_REMEMBER_DAYS)
    return timedelta(minutes=ACCESS_TOKEN_EXPIRE_MINUTES)


def get_user_from_token(token: str, db: Session) -> User:
    credentials_exception = HTTPException(
        status_code=status.HTTP_401_UNAUTHORIZED,
        detail="Could not validate credentials",
        headers={"WWW-Authenticate": "Bearer"},
    )
    try:
        payload = jwt.decode(token, SECRET_KEY, algorithms=[ALGORITHM])
        token_data = TokenData(
            user_id=payload.get("user_id"),
            email=payload.get("sub"),
        )
    except JWTError as exc:  # pragma: no cover - depends on malformed external tokens
        raise credentials_exception from exc

    if token_data.user_id is None:
        raise credentials_exception

    user = db.get(User, token_data.user_id)
    if user is None or not user.is_active:
        raise credentials_exception
    return user


def get_request_access_tokens(request: Request, bearer_token: str | None) -> list[str]:
    candidates: list[str] = []
    if bearer_token:
        candidates.append(bearer_token)

    cookie_token = request.cookies.get("pwsadmin_token")
    if cookie_token and cookie_token not in candidates:
        candidates.append(cookie_token)

    return candidates


def get_current_user(
    request: Request,
    token: str | None = Depends(oauth2_scheme),
    db: Session = Depends(get_admin_db),
) -> User:
    credentials_exception = HTTPException(
        status_code=status.HTTP_401_UNAUTHORIZED,
        detail="Could not validate credentials",
        headers={"WWW-Authenticate": "Bearer"},
    )
    access_tokens = get_request_access_tokens(request, token)
    if not access_tokens:
        raise credentials_exception

    last_exception: HTTPException = credentials_exception
    for access_token in access_tokens:
        try:
            return get_user_from_token(token=access_token, db=db)
        except HTTPException as exc:
            last_exception = exc

    raise last_exception
