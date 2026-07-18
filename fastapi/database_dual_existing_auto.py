import os
import re
from typing import Any
from urllib.parse import quote_plus

from sqlalchemy import create_engine, text
from sqlalchemy.orm import declarative_base, sessionmaker

POSTGRES_HOST = os.getenv("POSTGRES_HOST", "postgres")
POSTGRES_PORT = os.getenv("POSTGRES_PORT", "5432")
POSTGRES_USER = os.getenv("POSTGRES_USER", "n8n")
POSTGRES_PASSWORD = os.getenv("POSTGRES_PASSWORD", "")
ADMIN_PWS_DB = os.getenv("ADMIN_PWS_DB", "admin_pws")
AUTO_PWS_DB = os.getenv("AUTO_PWS_DB", "auto_pws")

Base = declarative_base()


def _build_database_url(database_name: str) -> str:
    encoded_password = quote_plus(POSTGRES_PASSWORD)
    return (
        f"postgresql+psycopg2://{POSTGRES_USER}:{encoded_password}"
        f"@{POSTGRES_HOST}:{POSTGRES_PORT}/{database_name}"
    )


admin_engine = create_engine(
    _build_database_url(ADMIN_PWS_DB),
    pool_pre_ping=True,
    future=True,
)
auto_engine = create_engine(
    _build_database_url(AUTO_PWS_DB),
    pool_pre_ping=True,
    future=True,
)

AdminSessionLocal = sessionmaker(
    autocommit=False,
    autoflush=False,
    bind=admin_engine,
    future=True,
)
AutoSessionLocal = sessionmaker(
    autocommit=False,
    autoflush=False,
    bind=auto_engine,
    future=True,
)

_WRITE_SQL_PATTERN = re.compile(
    r"\b(insert|update|delete|drop|alter|create|truncate|grant|revoke)\b",
    flags=re.IGNORECASE,
)
_DANGEROUS_SQL_PATTERN = re.compile(r"\b(drop|alter|truncate)\b", flags=re.IGNORECASE)

SECRETS_ENCRYPTION_KEY = (
    os.getenv("SECRETS_ENCRYPTION_KEY")
    or os.getenv("SECRET_ENCRYPTION_KEY")
    or ""
)
SECRETS_ENCRYPTION_KEY_ID = (
    os.getenv("SECRETS_ENCRYPTION_KEY_ID")
    or os.getenv("SECRETS_KEY_ID")
    or os.getenv("SECRET_ENCRYPTION_KEY_ID")
    or ""
)

_ALLOWED_AUTO_FUNCTIONS = {
    "set_secret",
    "get_secret",
    "update_secret",
    "delete_secret",
    "link_platform_property",
    "create_pricing_rule",
    "remove_pricing_rules",
    "update_pricing_rule",
}

_SAFE_FUNC_NAME_PATTERN = re.compile(r"^[a-zA-Z_][a-zA-Z0-9_.]*$")


def get_admin_db():
    db = AdminSessionLocal()
    try:
        yield db
    finally:
        db.close()


def get_auto_db():
    db = AutoSessionLocal()
    try:
        # Force auto_pws reads only for every transaction opened through this session.
        db.execute(text("SET default_transaction_read_only = on"))
        yield db
    finally:
        db.rollback()
        db.close()


def init_admin_db() -> None:
    # Import here to avoid circular imports during module initialization.
    import models_admin  # noqa: F401

    Base.metadata.create_all(bind=admin_engine)


def _check_connection(engine) -> tuple[bool, str]:
    try:
        with engine.connect() as connection:
            connection.execute(text("SELECT 1"))
        return True, "ok"
    except Exception as exc:  # pragma: no cover - runtime environment dependent
        return False, str(exc)


def check_admin_connection() -> tuple[bool, str]:
    return _check_connection(admin_engine)


def check_auto_connection() -> tuple[bool, str]:
    return _check_connection(auto_engine)


def _apply_session_settings(connection) -> None:
    """Apply per-session settings used by database functions (e.g., secrets)."""
    if SECRETS_ENCRYPTION_KEY:
        connection.execute(text("SET LOCAL app.secrets_key = :key"), {"key": SECRETS_ENCRYPTION_KEY})
    if SECRETS_ENCRYPTION_KEY_ID:
        connection.execute(
            text("SET LOCAL app.secrets_key_id = :key_id"), {"key_id": SECRETS_ENCRYPTION_KEY_ID}
        )


def _execute_auto(
    query: str,
    params: dict[str, Any] | None = None,
    *,
    fetch_one: bool = False,
    write: bool = False,
    expect_scalar: bool = False,
) -> list[dict[str, Any]] | dict[str, Any] | Any | None:
    normalized = query.strip().lower()

    if not write:
        if not normalized.startswith(("select", "with", "show", "explain")):
            raise ValueError("auto_pws query rejected: only read-only statements are allowed")
        if _WRITE_SQL_PATTERN.search(normalized):
            raise ValueError("auto_pws query rejected: write operations are not allowed")
    else:
        if _DANGEROUS_SQL_PATTERN.search(normalized):
            raise ValueError("auto_pws query rejected: dangerous write operation blocked")
        if ";" in query:
            raise ValueError("auto_pws query rejected: semicolons are not allowed in statements")

    rows: list[dict[str, Any]] | None = None
    with auto_engine.begin() as connection:
        if not write:
            connection.execute(text("SET LOCAL default_transaction_read_only = on"))
        _apply_session_settings(connection)
        result = connection.execute(text(query), params or {})
        if result.returns_rows:
            rows = [dict(row) for row in result.mappings().all()]

    if rows is None:
        # No rows returned (write-only statement)
        return None

    if expect_scalar:
        return list(rows[0].values())[0] if rows else None
    if fetch_one:
        return rows[0] if rows else None
    return rows


def execute_auto_query(
    query: str,
    params: dict[str, Any] | None = None,
    *,
    fetch_one: bool = False,
) -> list[dict[str, Any]] | dict[str, Any] | None:
    return _execute_auto(query, params, fetch_one=fetch_one, write=False)


def execute_auto_write(
    query: str,
    params: dict[str, Any] | None = None,
    *,
    fetch_one: bool = False,
) -> list[dict[str, Any]] | dict[str, Any] | None:
    return _execute_auto(query, params, fetch_one=fetch_one, write=True)


def execute_auto_function(
    func_name: str,
    params: dict[str, Any] | None = None,
    *,
    fetch_one: bool = False,
    write: bool = False,
    expect_scalar: bool = False,
) -> list[dict[str, Any]] | dict[str, Any] | Any | None:
    if not _SAFE_FUNC_NAME_PATTERN.match(func_name):
        raise ValueError("Function name contains invalid characters")
    if write and func_name not in _ALLOWED_AUTO_FUNCTIONS:
        raise ValueError(f"Function {func_name} is not allowlisted for writes")

    param_keys = params or {}
    placeholders = ", ".join(f":{key}" for key in param_keys)
    query = f"SELECT {func_name}({placeholders})"
    return _execute_auto(
        query,
        param_keys,
        fetch_one=fetch_one,
        write=write,
        expect_scalar=expect_scalar,
    )
