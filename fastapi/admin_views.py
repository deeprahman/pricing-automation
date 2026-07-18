from typing import Any

import anyio.to_thread
from sqlalchemy import func, inspect as sa_inspect, select
from sqlalchemy.ext.asyncio import AsyncSession
from starlette.requests import Request
from starlette_admin.contrib.sqla import ModelView
from starlette_admin.exceptions import ActionFailed, FormValidationError
from starlette_admin.fields import (
    BooleanField,
    DateTimeField,
    EmailField,
    IntegerField,
    PasswordField,
    StringField,
)

from auth import get_password_hash
from models_admin import User


class UserAdmin(ModelView):
    name = "User"
    label = "Users"
    icon = "fa fa-users"

    fields = [
        IntegerField("id", label="ID", read_only=True),
        EmailField("email", label="Email", required=True),
        StringField("username", label="Username", required=True),
        StringField("full_name", label="Full Name", required=False),
        PasswordField("hashed_password", label="Password", required=False),
        BooleanField("is_active", label="Active"),
        BooleanField("is_admin", label="Admin"),
        DateTimeField("created_at", label="Created At", read_only=True),
        DateTimeField("updated_at", label="Updated At", read_only=True),
    ]

    searchable_fields = ["email", "username", "full_name"]
    sortable_fields = ["id", "email", "username", "is_active", "is_admin", "created_at"]
    exclude_fields_from_list = ["hashed_password"]
    exclude_fields_from_detail = ["hashed_password"]

    async def before_create(self, request: Request, data: dict[str, Any], obj: Any) -> None:
        await self.on_model_change(data, obj, is_created=True)

    async def before_edit(self, request: Request, data: dict[str, Any], obj: Any) -> None:
        await self.on_model_change(data, obj, is_created=False)

    async def on_model_change(
        self,
        data: dict[str, Any],
        model: Any,
        *,
        is_created: bool,
    ) -> None:
        raw_password = data.get("hashed_password")
        if isinstance(raw_password, str):
            raw_password = raw_password.strip()

        if is_created and not raw_password:
            raise FormValidationError({"hashed_password": "Password is required"})

        if not raw_password:
            # Keep existing hash when editing without entering a new password.
            password_attr = sa_inspect(model).attrs.hashed_password
            if password_attr.history.deleted:
                model.hashed_password = password_attr.history.deleted[0]
            return

        if len(raw_password) < 8:
            raise FormValidationError({"hashed_password": "Password must be at least 8 characters"})

        model.hashed_password = get_password_hash(raw_password)

    async def delete(self, request: Request, pks: list[Any]) -> int | None:
        objects = await self.find_by_pks(request, pks)
        admins_to_delete = sum(1 for obj in objects if bool(getattr(obj, "is_admin", False)))

        if admins_to_delete > 0:
            session = request.state.session
            count_stmt = select(func.count()).select_from(User).where(User.is_admin.is_(True))
            if isinstance(session, AsyncSession):
                total_admins = (await session.execute(count_stmt)).scalar_one()
            else:
                total_admins = (
                    await anyio.to_thread.run_sync(session.execute, count_stmt)
                ).scalar_one()

            if total_admins - admins_to_delete < 1:
                raise ActionFailed("Cannot delete the last admin user")

        return await super().delete(request, pks)

